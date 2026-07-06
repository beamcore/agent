defmodule Beamcore.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.{State, Theme}
  alias Beamcore.TUI.Events.Commands

  setup do
    original = Theme.current_theme()

    on_exit(fn ->
      Theme.set_theme(original)
    end)

    state = %State{
      textarea: ExRatatui.textarea_new(),
      session: nil,
      messages: []
    }

    %{state: state}
  end

  test "/theme opens popup", %{state: state} do
    result = Commands.run_command(state, "theme")
    assert result.show_theme_picker == true
    assert result.render_dirty? == true
  end

  test "set_theme switches theme and marks dirty" do
    Theme.set_theme(:catppuccin)
    assert Theme.current_theme() == :catppuccin
  end

  test "default theme uses terminal defaults" do
    Theme.set_theme(:default)
    base = Theme.style(:base)
    assert base.fg == nil
    assert base.bg == nil
    assert base.modifiers == []

    panel = Theme.style(:panel)
    assert panel.fg == nil
    assert panel.bg == nil

    input = Theme.style(:input)
    assert input.fg == nil
    assert input.bg == nil
  end

  test "all themes have all required style keys" do
    required_keys = [
      :base,
      :muted,
      :subtle,
      :title,
      :panel,
      :border,
      :border_hot,
      :user,
      :assistant,
      :system,
      :accent,
      :running,
      :queued,
      :done,
      :memory,
      :error,
      :input,
      :cursor,
      :thinking,
      :status,
      :status_hot,
      :syntax_keyword,
      :syntax_comment,
      :syntax_string,
      :syntax_atom,
      :syntax_number,
      :syntax_module,
      :syntax_operator,
      :syntax_default
    ]

    for theme_name <- Theme.list_themes() do
      Theme.set_theme(theme_name)

      for key <- required_keys do
        style = Theme.style(key)
        assert %ExRatatui.Style{} = style, "Theme #{theme_name} missing key #{key}"
      end
    end
  end
end
