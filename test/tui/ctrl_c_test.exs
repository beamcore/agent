defmodule Beamcore.TUI.CtrlCTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.{Events, State}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{"MISTRAL_API_KEY" => "test-api-key"})
    session_id = "tui-ctrlc-#{System.unique_integer([:positive])}"
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

    %{state: state}
  end

  defp key(code, mods \\ []) do
    %ExRatatui.Event.Key{code: code, modifiers: mods, kind: :press}
  end

  defp ctrl_c, do: key("c", ["ctrl"])

  test "first Ctrl+C while idle arms exit, second quits", %{state: state} do
    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert state.ctrl_c_pending == :exit
    assert State.ctrl_c_hint(state.ctrl_c_pending) =~ "exit"

    assert {:stop, _state} = Events.handle_event(ctrl_c(), state)
  end

  test "first Ctrl+C while running arms pause, second pauses the session", %{state: state} do
    state = %{state | worker: spawn(fn -> Process.sleep(:infinity) end), status: :thinking}

    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert state.ctrl_c_pending == :pause
    assert State.ctrl_c_hint(state.ctrl_c_pending) =~ "pause"

    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert State.paused?(state)
    assert state.worker == nil
    assert state.ctrl_c_pending == false
  end

  test "a non Ctrl+C keypress disarms the pending action", %{state: state} do
    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert state.ctrl_c_pending == :exit

    {:noreply, state} = Events.handle_event(key("x"), state)
    assert state.ctrl_c_pending == false
  end

  test "context switch between presses re-arms instead of confirming", %{state: state} do
    running = %{state | worker: spawn(fn -> Process.sleep(:infinity) end), status: :thinking}

    {:noreply, running} = Events.handle_event(ctrl_c(), running)
    assert running.ctrl_c_pending == :pause

    idle = %{running | worker: nil, status: :idle}

    {:noreply, idle} = Events.handle_event(ctrl_c(), idle)
    assert idle.ctrl_c_pending == :exit
  end

  test "Ctrl+C while paused arms exit and second press quits", %{state: state} do
    state = State.pause(state)

    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert state.ctrl_c_pending == :exit

    assert {:stop, _state} = Events.handle_event(ctrl_c(), state)
  end

  test "sending a plain message after a Ctrl+C pause resumes and starts a turn", %{state: state} do
    state = %{state | worker: spawn(fn -> Process.sleep(:infinity) end), status: :thinking}

    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert State.paused?(state)

    ExRatatui.textarea_set_value(state.textarea, "go this way instead")
    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)

    refute State.paused?(state)
    assert state.worker != nil
    assert ExRatatui.textarea_get_value(state.textarea) |> String.trim() == ""
    assert Enum.any?(state.messages, &(&1.role == :user and &1.content == "go this way instead"))
  end

  test "first Ctrl+C clears a non-empty composer without arming exit", %{state: state} do
    ExRatatui.textarea_set_value(state.textarea, "half-typed message")

    {:noreply, state} = Events.handle_event(ctrl_c(), state)

    assert ExRatatui.textarea_get_value(state.textarea) == ""
    assert state.ctrl_c_pending == false
  end

  test "Ctrl+C after clearing the composer arms exit, then quits", %{state: state} do
    ExRatatui.textarea_set_value(state.textarea, "draft")

    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert ExRatatui.textarea_get_value(state.textarea) == ""

    {:noreply, state} = Events.handle_event(ctrl_c(), state)
    assert state.ctrl_c_pending == :exit

    assert {:stop, _state} = Events.handle_event(ctrl_c(), state)
  end

  test "Ctrl+C with text while running clears the composer instead of pausing", %{state: state} do
    state = %{state | worker: spawn(fn -> Process.sleep(:infinity) end), status: :thinking}
    ExRatatui.textarea_set_value(state.textarea, "scratch")

    {:noreply, state} = Events.handle_event(ctrl_c(), state)

    assert ExRatatui.textarea_get_value(state.textarea) == ""
    assert state.ctrl_c_pending == false
    refute State.paused?(state)
  end
end
