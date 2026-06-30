defmodule Beamcore.TUI.HelpToggleTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.{MultiScreenState, State}

  defp key(code), do: %ExRatatui.Event.Key{code: code, kind: "press", modifiers: []}

  defp multi(mode) do
    %MultiScreenState{
      active_mode: mode,
      chat_state: State.new(nil, ExRatatui.textarea_new()),
      dashboard_state: TuiSystem.new(:agent)
    }
  end

  test "? opens the shell help in a no-composer mode and toggles it off" do
    {:noreply, opened} = TUI.handle_event(key("?"), multi(:dashboard))
    assert opened.show_help

    {:noreply, closed} = TUI.handle_event(key("?"), opened)
    refute closed.show_help
  end

  test "esc closes the shell help in a no-composer mode" do
    {:noreply, closed} = TUI.handle_event(key("esc"), %{multi(:research) | show_help: true})
    refute closed.show_help
  end

  test "? on an empty composer opens chat help, not the shell-level flag" do
    {:noreply, opened} = TUI.handle_event(key("?"), multi(:chat))
    assert opened.chat_state.show_help
    refute opened.show_help
  end

  test "? with text already in the composer is typed, not a help toggle" do
    {:noreply, typed} =
      TUI.handle_event(
        %ExRatatui.Event.Key{code: "a", kind: "press", modifiers: []},
        multi(:chat)
      )

    {:noreply, after_q} = TUI.handle_event(key("?"), typed)

    refute after_q.chat_state.show_help
    assert ExRatatui.textarea_get_value(after_q.chat_state.textarea) == "a?"
  end
end
