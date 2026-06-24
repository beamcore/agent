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

  test "normal character input is handled on press events and marks state dirty" do
    {:noreply, updated} =
      Events.handle_event(key("a", "press"), %{state() | render_dirty?: false})

    assert value(updated) == "a"
    assert updated.render_dirty?
  end

  test "atom press key events are handled and mark state dirty" do
    {:noreply, updated} = Events.handle_event(key("a", :press), %{state() | render_dirty?: false})
    assert value(updated) == "a"
    assert updated.render_dirty?
  end

  test "events with nil kind are handled for legacy/manual events and mark dirty" do
    {:noreply, updated} = Events.handle_event(key("b", nil), %{state() | render_dirty?: false})
    assert value(updated) == "b"
    assert updated.render_dirty?
  end

  test "standard key events are handled as input and mark dirty" do
    {:noreply, updated} =
      Events.handle_event(key(".", "standard"), %{state() | render_dirty?: false})

    assert value(updated) == "."
    assert updated.render_dirty?

    {:noreply, updated} =
      Events.handle_event(key(",", :standard), %{state() | render_dirty?: false})

    assert value(updated) == ","
    assert updated.render_dirty?
  end

  test "unknown key event kinds are treated as actionable input" do
    {:noreply, updated} =
      Events.handle_event(key("c", "unknown"), %{state() | render_dirty?: false})

    assert value(updated) == "c"
    assert updated.render_dirty?
  end

  test "release and repeat key events are ignored" do
    initial = %{state() | render_dirty?: false}

    {:noreply, updated} = Events.handle_event(key("d", "release"), initial)
    assert value(updated) == ""
    refute updated.render_dirty?

    {:noreply, updated} = Events.handle_event(key("d", :release), updated)
    assert value(updated) == ""
    refute updated.render_dirty?

    {:noreply, updated} = Events.handle_event(key("d", "repeat"), updated)
    assert value(updated) == ""
    refute updated.render_dirty?

    {:noreply, updated} = Events.handle_event(key("d", :repeat), updated)
    assert value(updated) == ""
    refute updated.render_dirty?
  end

  test "repeated character input marks state dirty every time" do
    updated =
      Enum.reduce(~w(h e l l o), %{state() | render_dirty?: false}, fn char, acc ->
        acc = %{acc | render_dirty?: false}
        {:noreply, acc} = Events.handle_event(key(char, "press"), acc)
        assert acc.render_dirty?
        acc
      end)

    assert value(updated) == "hello"
  end

  test "enter inserts a newline" do
    {:noreply, updated} = Events.handle_event(key("enter"), state())
    assert value(updated) == "\n"
  end

  test "resize marks state dirty and does not enter text path" do
    initial = %{state() | render_dirty?: false}

    {:noreply, updated} =
      Events.handle_event(%ExRatatui.Event.Resize{width: 100, height: 30}, initial)

    assert value(updated) == ""
    assert updated.render_dirty?
  end

  test "Ctrl+C is recognized and does not insert text" do
    initial = %{state() | render_dirty?: false}

    {:noreply, updated} =
      Events.handle_event(
        %ExRatatui.Event.Key{code: "c", modifiers: ["ctrl"], kind: "press"},
        initial
      )

    assert value(updated) == ""
    assert updated.ctrl_c_pending == :exit
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
      refute KeyEvents.actionable?(key("f#{n}", "repeat"))
      assert KeyEvents.actionable?(key("f#{n}", nil))
      assert KeyEvents.actionable?(key("f#{n}", "standard"))
      assert KeyEvents.actionable?(key("f#{n}", "unknown"))
      refute KeyEvents.actionable?(key("f#{n}", "release"))
    end
  end

  test "top-level TUI suppresses render for release and repeat events before dispatch" do
    multi = %MultiScreenState{
      active_screen: :f1,
      f1_state: state(),
      f2_state: state(),
      f3_state: Components.System.new(:agent)
    }

    assert {:noreply, ^multi, [render?: false]} = TUI.handle_event(key("f3", "release"), multi)
    assert {:noreply, ^multi, [render?: false]} = TUI.handle_event(key("f3", "repeat"), multi)
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

  test "F3 provider form accepts valid non-release kinds and ignores repeat/release" do
    system = Components.System.new(:agent)
    {:noreply, system} = Events.handle_event(key("a"), system)
    {:noreply, system} = Events.handle_event(key("x", "repeat"), system)
    {:noreply, system} = Events.handle_event(key("y", "unknown"), system)
    {:noreply, system} = Events.handle_event(key("s", "standard"), system)
    {:noreply, system} = Events.handle_event(key("z", "release"), system)

    assert system.providers.adding?
    assert system.providers.form.name == "ys"
  end

  test "help modal does not swallow ordinary valid text input" do
    initial = %{state() | show_help: true, render_dirty?: false}

    {:noreply, updated} = Events.handle_event(key("x", "press"), initial)

    assert value(updated) == "x"
    assert updated.show_help
    assert updated.render_dirty?
  end
end
