defmodule Beamcore.TUI.ThemeTest do
  # async: false — these tests mutate the global theme (Application env), which
  # other suites read when comparing styles (chip/pill/tab). Running serially
  # keeps those concurrent reads stable.
  use ExUnit.Case, async: false

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

  test "chip_style derives a filled chip from the theme accent color" do
    Theme.set_theme(:default)
    accent = Theme.style(:accent)
    chip = Theme.chip_style()

    assert chip.bg == accent.fg
    assert chip.fg == :black
    assert :bold in chip.modifiers
  end

  test "chip_style follows the active theme's accent" do
    Theme.set_theme(:dracula)
    assert Theme.chip_style().bg == Theme.style(:accent).fg
  end

  test "chip text flips to white on dark-accent themes for legibility" do
    Theme.set_theme(:github)
    assert Theme.chip_style().fg == :white

    Theme.set_theme(:solarized)
    assert Theme.chip_style().fg == :white
  end

  test "chip text stays black on bright-accent themes" do
    Theme.set_theme(:matrix)
    assert Theme.chip_style().fg == :black

    # A named terminal accent (default theme's :cyan) keeps black text.
    Theme.set_theme(:default)
    assert Theme.chip_style().fg == :black
  end

  test "key_pill wraps a label in a padded chip span" do
    Theme.set_theme(:default)
    pill = Theme.key_pill("^C")

    assert %ExRatatui.Text.Span{} = pill
    assert pill.content == " ^C "
    assert pill.style == Theme.chip_style()
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
