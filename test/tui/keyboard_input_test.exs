defmodule Beamcore.TUI.KeyboardInputTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components
  alias Beamcore.TUI.Events
  alias Beamcore.TUI.Events.KeyEvents
  alias Beamcore.TUI
  alias Beamcore.TUI.{MultiScreenState, State}

  defp state do
    %State{
      textarea: ExRatatui.textarea_new(),
      messages: [],
      activity: [],
      status: :idle,
      unicode?: true,
      screen_type: :chat
    }
  end

  defp key(code, kind \\ "press", mods \\ []) do
    %ExRatatui.Event.Key{code: code, kind: kind, modifiers: mods}
  end

  defp value(state), do: ExRatatui.textarea_get_value(state.textarea)

  test "normal character input is handled on press events" do
    {:noreply, updated} = Events.handle_event(key("a", "press"), state())
    assert value(updated) == "a"
  end

  test "events with nil kind are handled for legacy/manual events" do
    {:noreply, updated} = Events.handle_event(key("b", nil), state())
    assert value(updated) == "b"
  end

  test "repeat key events are handled as input" do
    state =
      Enum.reduce([key("a", "press"), key("a", "repeat"), key("a", :repeat)], state(), fn event,
                                                                                          acc ->
        {:noreply, acc} = Events.handle_event(event, acc)
        acc
      end)

    assert value(state) == "aaa"
  end

  test "unknown key event kinds are treated as actionable input" do
    {:noreply, updated} = Events.handle_event(key("c", "unknown"), state())
    assert value(updated) == "c"
  end

  test "release key events are ignored" do
    {:noreply, updated} = Events.handle_event(key("d", "release"), state())
    assert value(updated) == ""

    {:noreply, updated} = Events.handle_event(key("d", :release), updated)
    assert value(updated) == ""
  end

  test "repeated typing does not drop repeat events" do
    events = [
      key("h", "press"),
      key("e", "press"),
      key("l", "press"),
      key("l", "repeat"),
      key("o", "press")
    ]

    updated =
      Enum.reduce(events, state(), fn event, acc ->
        {:noreply, acc} = Events.handle_event(event, acc)
        acc
      end)

    assert value(updated) == "hello"
  end

  test "enter inserts a newline" do
    {:noreply, updated} = Events.handle_event(key("enter"), state())
    assert value(updated) == "\n"
  end

  test "escape closes modal panels without altering input" do
    initial = %{state() | show_help: true, show_commands: true, show_theme_picker: true}

    {:noreply, updated} = Events.handle_event(key("esc"), initial)

    assert value(updated) == ""
    refute updated.show_help
    refute updated.show_commands
    refute updated.show_theme_picker
  end

  test "function keys F1 through F12 have explicit actionable-kind coverage" do
    for n <- 1..12 do
      assert KeyEvents.actionable?(key("f#{n}", "press"))
      assert KeyEvents.actionable?(key("f#{n}", "repeat"))
      assert KeyEvents.actionable?(key("f#{n}", nil))
      assert KeyEvents.actionable?(key("f#{n}", "unknown"))
      refute KeyEvents.actionable?(key("f#{n}", "release"))
    end
  end

  test "top-level TUI suppresses render for release events before dispatch" do
    multi = %MultiScreenState{
      active_screen: :f1,
      f1_state: state(),
      f2_state: state(),
      f3_state: Components.System.new(:agent)
    }

    assert {:noreply, ^multi, [render?: false]} = TUI.handle_event(key("f3", "release"), multi)
  end

  test "F3 press still switches to the system screen" do
    multi = %MultiScreenState{
      active_screen: :f1,
      f1_state: state(),
      f2_state: state(),
      f3_state: Components.System.new(:agent)
    }

    {:noreply, updated} = TUI.handle_event(key("f3", "press"), multi)
    assert updated.active_screen == :f3
  end

  test "F3 provider form accepts repeat and unknown key kinds" do
    system = Components.System.new(:agent)
    {:noreply, system} = Events.handle_event(key("a"), system)
    {:noreply, system} = Events.handle_event(key("x", "repeat"), system)
    {:noreply, system} = Events.handle_event(key("y", "unknown"), system)
    {:noreply, system} = Events.handle_event(key("z", "release"), system)

    assert system.providers.adding?
    assert system.providers.form.name == "xy"
  end
end
