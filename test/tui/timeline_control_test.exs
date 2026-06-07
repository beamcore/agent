defmodule Beamcore.TUI.TimelineControlTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.{Events, State}
  alias Beamcore.TUI.Components.Activity

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{"MISTRAL_API_KEY" => "test-api-key"})
    session_id = "tui-timeline-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), session_id)
    File.mkdir_p!(tmp_dir)

    session =
      Beamcore.OpenAI.client()
      |> Session.new(session_id: session_id, screen_type: :chat)
      |> Map.put(:state_file, Path.join(tmp_dir, "session.state.json"))
      |> Map.put(:checkpoint_file, Path.join(tmp_dir, "session.checkpoints.json"))

    state = %State{
      textarea: ExRatatui.textarea_new(),
      session: session,
      messages: [],
      activity: [],
      status: :idle,
      unicode?: true,
      screen_type: :chat
    }

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{state: state, session: session}
  end

  test "command palette exposes timeline control commands" do
    names = Enum.map(Events.commands(), & &1.name)

    assert "checkpoint rewind " in names
    assert "checkpoint fork " in names
    assert "checkpoint abandon " in names
    refute "confirm" in names
  end

  test "TUI can render timeline branches", %{state: state} do
    session =
      state.session
      |> Session.append_timeline(:decision, "Checkpoint A.")

    state = %{state | session: session}
    items = State.timeline_items(state)

    assert Enum.any?(items, &String.contains?(&1.label, "Decision"))
    refute Enum.any?(items, &(&1.name == "checkpoint_saved"))
    assert Activity.compact_text(%{state | activity: items}) =~ "Decision"
  end

  test "timeline rendering does not show blank reversible values", %{state: state} do
    session =
      state.session
      |> Session.append_timeline(:decision, "Checkpoint A.")

    state = %{state | session: session}
    item = State.timeline_items(state) |> Enum.find(&(&1.name == "decision"))
    text = Activity.details_lines(item, 0, 1, 120) |> Enum.join("\n")

    refute text =~ "reversible: \n"
    refute text =~ "reversible: nil"
    assert text =~ "reversible: true"
  end

  test "TUI can trigger interrupt", %{state: state} do
    {:ok, worker} = Task.start(fn -> Process.sleep(:infinity) end)
    state = %{state | worker: worker, status: :thinking}

    state = submit_command(state, "/stop")

    assert state.status == :paused
    assert state.worker == nil
    assert state.session.interrupted?
    assert Enum.any?(state.session.timeline, &(&1.type == :interrupted))
  end

  test "TUI can trigger resume", %{state: state} do
    session = Session.interrupt(state.session, "Paused.")
    state = %{state | session: session, status: :paused}

    state = submit_command(state, "/resume")

    assert state.status == :idle
    refute state.session.interrupted?
    assert Enum.any?(state.session.timeline, &(&1.type == :resumed))
  end

  test "TUI can trigger rewind and fork from a checkpoint", %{state: state} do
    session = Session.append_timeline(state.session, :decision, "Checkpoint A.")
    checkpoint_a = session.active_checkpoint_id
    session = Session.append_timeline(session, :decision, "Checkpoint B.")
    state = %{state | session: session}

    rewound = submit_command(state, "/checkpoint rewind #{checkpoint_a}")
    assert rewound.session.active_checkpoint_id == checkpoint_a
    assert Enum.any?(rewound.session.timeline, &(&1.type == :rewound))

    forked = submit_command(rewound, "/checkpoint fork #{checkpoint_a}")
    assert forked.session.branch_id != rewound.session.branch_id
    assert Enum.any?(forked.session.timeline, &(&1.type == :forked))
  end

  test "TUI can trigger abandon branch", %{state: state} do
    branch_id = state.session.branch_id

    state = submit_command(state, "/checkpoint abandon #{branch_id}")

    assert state.session.branches[branch_id].status == :abandoned
  end

  defp submit_command(state, command) do
    ExRatatui.textarea_set_value(state.textarea, command)
    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)
    state
  end

  defp key(code, mods) do
    %ExRatatui.Event.Key{code: code, modifiers: mods, kind: :press}
  end
end
