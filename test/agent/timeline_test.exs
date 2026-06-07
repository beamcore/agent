defmodule Beamcore.Agent.TimelineTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Timeline

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{"MISTRAL_API_KEY" => "test-api-key"})
    session_id = "timeline-test-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), session_id)
    File.mkdir_p!(tmp_dir)

    session =
      Beamcore.OpenAI.client()
      |> Session.new(session_id: session_id, screen_type: :chat)
      |> Map.put(:state_file, Path.join(tmp_dir, "session.state.json"))
      |> Map.put(:checkpoint_file, Path.join(tmp_dir, "session.checkpoints.json"))

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{session: session, tmp_dir: tmp_dir}
  end

  test "important events create durable checkpoints", %{session: session} do
    session =
      Session.append_timeline(session, :decision, "Inspected provider registry.",
        role: :agent,
        title: "Decision"
      )

    assert [_started, decision, checkpoint_event] = session.timeline
    assert decision.type == :decision
    assert checkpoint_event.type == :checkpoint_saved
    assert [checkpoint] = session.checkpoints
    assert checkpoint.event_id == decision.id
    assert session.active_checkpoint_id == checkpoint.id
    assert File.exists?(session.checkpoint_file)
  end

  test "interrupt preserves the current checkpoint", %{session: session} do
    session = Session.append_timeline(session, :decision, "Before interrupt.")
    checkpoint_id = session.active_checkpoint_id

    session = Session.interrupt(session, "User interrupted.")

    assert session.interrupted?
    assert session.active_checkpoint_id != nil
    assert Enum.any?(session.checkpoints, &(&1.id == checkpoint_id))
    assert Enum.any?(session.timeline, &(&1.type == :interrupted))
  end

  test "resume continues current branch", %{session: session} do
    session = Session.interrupt(session, "Paused.")
    branch_id = session.branch_id

    session = Session.resume_interrupted(session, "Resumed.")

    refute session.interrupted?
    assert session.branch_id == branch_id
    assert Enum.any?(session.timeline, &(&1.type == :resumed))
  end

  test "rewind selects an earlier checkpoint without deleting later history", %{session: session} do
    session = Session.append_timeline(session, :decision, "Checkpoint A.")
    checkpoint_a = session.active_checkpoint_id
    session = Session.append_timeline(session, :decision, "Checkpoint B.")
    event_count = length(session.timeline)

    assert {:ok, rewound} = Session.rewind(session, checkpoint_a)

    assert rewound.active_checkpoint_id == checkpoint_a
    assert length(rewound.timeline) > event_count
    assert Enum.any?(rewound.timeline, &(&1.type == :rewound))
    assert Enum.any?(rewound.timeline, &(&1.status == :abandoned))
  end

  test "fork creates a new branch without deleting old history", %{session: session} do
    session = Session.append_timeline(session, :decision, "Checkpoint A.")
    checkpoint_a = session.active_checkpoint_id
    old_branch = session.branch_id

    assert {:ok, forked} = Session.fork(session, checkpoint_a)

    assert forked.branch_id != old_branch
    assert Map.has_key?(forked.branches, old_branch)
    assert Map.has_key?(forked.branches, forked.branch_id)
    assert Enum.any?(forked.timeline, &(&1.type == :forked))
  end

  test "continuing from fork does not mutate abandoned branch", %{session: session} do
    session = Session.append_timeline(session, :decision, "Checkpoint A.")
    checkpoint_a = session.active_checkpoint_id
    old_branch = session.branch_id
    {:ok, forked} = Session.fork(session, checkpoint_a)
    forked = Session.abandon_branch(forked, old_branch, "Bad branch.")

    continued = Session.append_timeline(forked, :decision, "New branch decision.")

    assert continued.branch_id == forked.branch_id
    assert continued.branches[old_branch].status == :abandoned
    assert List.last(continued.timeline).branch_id == continued.branch_id
  end

  test "bad branch can be abandoned", %{session: session} do
    branch_id = session.branch_id
    session = Session.abandon_branch(session, branch_id, "Bad path.")

    assert session.branches[branch_id].status == :abandoned
    assert Enum.any?(session.timeline, &(&1.summary == "Bad path."))
  end

  test "state loads safely from JSON without unsafe atom creation", %{tmp_dir: tmp_dir} do
    malicious = "untrusted_atom_#{System.unique_integer([:positive])}"
    session_id = "unsafe-#{System.unique_integer([:positive])}"
    session_dir = Path.join([System.user_home!(), ".agent", "sessions"])
    File.mkdir_p!(session_dir)
    state_file = Path.join(session_dir, "#{session_id}.state.json")

    on_exit(fn -> File.rm(state_file) end)

    File.write!(
      state_file,
      Jason.encode!(%{
        "session_id" => session_id,
        "log_file" => Path.join(tmp_dir, "unsafe.json"),
        "state_file" => state_file,
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "screen_type" => "chat",
        "timeline" => [%{"type" => malicious, "role" => malicious, "status" => malicious}]
      })
    )

    assert {:ok, resumed} = Session.resume(session_id, Beamcore.OpenAI.client(), [])
    assert hd(resumed.timeline).type == :decision
    assert_raise ArgumentError, fn -> String.to_existing_atom(malicious) end
  end

  test "checkpoint writes are atomic", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "atomic.json")

    assert :ok = Timeline.write_atomic!(path, %{"ok" => true})
    assert File.read!(path) == ~s({"ok":true})
    assert Path.wildcard(path <> ".tmp-*") == []
  end
end
