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

  test "timeline details show filesystem revision metadata", %{state: state} do
    session =
      state.session
      |> Session.append_timeline(:decision, "Checkpoint A.")

    state = %{state | session: session}
    item = State.timeline_items(state) |> Enum.find(&(&1.name == "decision"))
    text = Activity.details_lines(item, 0, 1, 120) |> Enum.join("\n")

    assert text =~ "filesystem_revision:"
    assert text =~ "filesystem_paths:"
    assert text =~ "filesystem_bytes:"
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
    assert rewound.status == :restoring
    assert_receive {:restore_progress, _restore_id, %{phase: "requested"}}
    assert_receive {:restore_progress, _restore_id, %{phase: "planned"}}

    assert_receive {:restore_completed, _restore_id, :rewind, ^checkpoint_a,
                    {:ok, session, filesystem_result}}

    rewound =
      Events.handle_restore_completed(
        :rewind,
        checkpoint_a,
        {:ok, session, filesystem_result},
        rewound
      )

    assert rewound.session.active_checkpoint_id == checkpoint_a
    assert Enum.any?(rewound.session.timeline, &(&1.type == :rewound))

    forked = submit_command(rewound, "/checkpoint fork #{checkpoint_a}")
    assert forked.status == :restoring

    assert_receive {:restore_completed, _restore_id, :fork, ^checkpoint_a,
                    {:ok, session, filesystem_result}}

    forked =
      Events.handle_restore_completed(
        :fork,
        checkpoint_a,
        {:ok, session, filesystem_result},
        forked
      )

    assert forked.session.branch_id != rewound.session.branch_id
    assert Enum.any?(forked.session.timeline, &(&1.type == :forked))
  end

  test "TUI can trigger abandon branch", %{state: state} do
    branch_id = state.session.branch_id

    state = submit_command(state, "/checkpoint abandon #{branch_id}")

    assert state.session.branches[branch_id].status == :abandoned
  end

  test "Activity keyboard navigation changes selected event", %{state: state} do
    state = %{state | session: timeline_session(state.session, 5)}

    {:noreply, state} = Events.handle_event(key("f6"), state)
    assert state.activity_focused?

    {:noreply, state} = Events.handle_event(key("end"), state)
    newest = state.selected_activity
    assert newest == length(State.timeline_items(state)) - 1

    {:noreply, state} = Events.handle_event(key("k"), state)
    assert state.selected_activity == newest - 1

    {:noreply, state} = Events.handle_event(key("j"), state)
    assert state.selected_activity == newest
  end

  test "Ctrl+A does not globally steal input focus for Activity", %{state: state} do
    {:noreply, state} = Events.handle_event(key("a", ["ctrl"]), state)

    refute state.activity_focused?

    {:noreply, state} = Events.handle_event(key("f6"), state)
    assert state.activity_focused?
  end

  test "Ctrl+L is not a global Activity focus binding", %{state: state} do
    {:noreply, state} = Events.handle_event(key("l", ["ctrl"]), state)
    refute state.activity_focused?
  end

  test "Activity page, home, and end navigation", %{state: state} do
    state =
      %{state | session: timeline_session(state.session, 12)}
      |> State.set_activity_viewport_height(4)
      |> State.activity_end()

    newest = state.selected_activity
    {:noreply, state} = Events.handle_event(key("page_up"), state)
    assert state.selected_activity <= newest - 2

    {:noreply, state} = Events.handle_event(key("home"), state)
    assert state.selected_activity == 0
    refute state.activity_follow_tail?

    {:noreply, state} = Events.handle_event(key("G"), state)
    assert state.selected_activity == length(State.timeline_items(state)) - 1
    assert state.activity_follow_tail?
    assert state.activity_unseen_count == 0
  end

  test "Activity live follow pauses when user scrolls upward", %{state: state} do
    state =
      %{state | session: timeline_session(state.session, 3)}
      |> State.activity_end()

    state = State.scroll_activity_up(state, 3)
    refute state.activity_follow_tail?

    session = Session.append_timeline(state.session, :decision, "New event.")
    state = State.set_session(state, session)

    assert state.activity_unseen_count > 0

    state = State.activity_end(state)
    assert state.activity_follow_tail?
    assert state.activity_unseen_count == 0
  end

  test "Activity visible items slices long timeline", %{state: state} do
    state =
      %{state | session: timeline_session(state.session, 80)}
      |> State.set_activity_viewport_height(6)
      |> State.activity_end()

    visible = State.visible_timeline_items(state, 6)

    assert length(visible) < length(State.timeline_items(state))
    assert List.last(visible).id == List.last(State.timeline_items(state)).id
  end

  test "Activity viewport rendering remains bounded for large timelines", %{state: state} do
    state =
      %{state | session: in_memory_timeline_session(state.session, 5_000)}
      |> State.set_activity_viewport_height(14)
      |> State.activity_end()

    {micros, visible} = :timer.tc(fn -> State.visible_timeline_items(state, 14) end)

    assert length(visible) <= 18
    assert micros < 100_000
  end

  test "Activity viewport rendering remains bounded for very large timelines", %{state: state} do
    state =
      %{state | session: in_memory_timeline_session(state.session, 50_000)}
      |> State.set_activity_viewport_height(14)
      |> State.activity_end()

    {micros, visible} = :timer.tc(fn -> State.visible_timeline_items(state, 14) end)

    assert length(visible) <= 18
    assert micros < 750_000
  end

  test "selected checkpoint opens detail view", %{state: state} do
    session = Session.append_timeline(state.session, :decision, "Checkpoint A.")
    state = %{state | session: session} |> State.activity_end() |> State.focus_activity()

    {:noreply, state} = Events.handle_event(key("enter"), state)

    assert state.show_activity_details
    assert State.selected_checkpoint(state).id == session.active_checkpoint_id
  end

  test "Activity rewind and fork actions call shared session services", %{state: state} do
    session = Session.append_timeline(state.session, :decision, "Checkpoint A.")
    checkpoint_id = session.active_checkpoint_id
    session = Session.append_timeline(session, :decision, "Checkpoint B.")

    state =
      %{state | session: session}
      |> State.focus_activity()
      |> State.select_checkpoint(checkpoint_id)

    {:noreply, rewound} =
      Events.handle_event(key("r", ["ctrl"]), %{state | show_activity_details: true})

    assert rewound.status == :restoring
    assert_receive {:restore_progress, _restore_id, %{phase: "requested"}}

    assert_receive {:restore_completed, _restore_id, :rewind, ^checkpoint_id,
                    {:ok, session, filesystem_result}}

    rewound =
      Events.handle_restore_completed(
        :rewind,
        checkpoint_id,
        {:ok, session, filesystem_result},
        rewound
      )

    assert rewound.session.active_checkpoint_id == checkpoint_id

    {:noreply, forked} =
      Events.handle_event(key("f", ["ctrl"]), %{rewound | show_activity_details: true})

    assert forked.status == :restoring

    assert_receive {:restore_completed, _restore_id, :fork, ^checkpoint_id,
                    {:ok, session, filesystem_result}}

    forked =
      Events.handle_restore_completed(
        :fork,
        checkpoint_id,
        {:ok, session, filesystem_result},
        forked
      )

    assert forked.session.branch_id != rewound.session.branch_id
  end

  test "Activity viewport clamps on very small height", %{state: state} do
    state =
      %{state | session: timeline_session(state.session, 4)}
      |> State.set_activity_viewport_height(0)
      |> State.activity_page(:up)

    assert state.selected_activity >= 0
    assert is_list(State.visible_timeline_items(state, 0))
  end


  test "checkpoint items are highlighted and include chat orientation", %{state: state} do
    session =
      state.session
      |> Map.put(:messages, [%{role: :user, content: "Implement policy-aware Eeva"}])
      |> Session.append_timeline(:decision, "Goal accepted.")

    item =
      %{state | session: session}
      |> State.timeline_items()
      |> Enum.find(& &1.checkpoint?)

    assert item.checkpoint?
    assert item.args.chat_message >= 1
    assert item.args.checkpoint_description =~ "Implement policy-aware Eeva"

    details = Activity.details_lines(item, 0, 1, 120) |> Enum.join("\n")
    assert details =~ "chat reference: message #"
    assert details =~ "Implement policy-aware Eeva"
  end

  test "activity retains a larger rolling history", %{state: state} do
    state =
      Enum.reduce(1..520, state, fn index, acc ->
        State.add_activity(acc, "eeva", %{"code" => "#{index}"}, :done)
      end)

    assert length(state.activity) == 500
  end


  defp submit_command(state, command) do
    ExRatatui.textarea_set_value(state.textarea, command)
    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)
    state
  end

  defp key(code, mods) do
    %ExRatatui.Event.Key{code: code, modifiers: mods, kind: :press}
  end

  defp key(code), do: key(code, [])

  defp timeline_session(session, count) do
    Enum.reduce(1..count, session, fn index, session ->
      Session.append_timeline(session, :decision, "Timeline event #{index}.",
        title: "Decision #{index}"
      )
    end)
  end

  defp in_memory_timeline_session(session, count) do
    timeline =
      Enum.map(1..count, fn index ->
        Beamcore.Agent.Timeline.event(session, %{
          id: "perf-evt-#{index}",
          type: :decision,
          title: "Decision #{index}",
          summary: "Timeline event #{index}.",
          timestamp: "2026-06-08T00:00:00Z"
        })
      end)

    %{session | timeline: timeline}
  end
end
