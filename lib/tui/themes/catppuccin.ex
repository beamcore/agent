defmodule Beamcore.TUI.Themes.Catppuccin do
  @moduledoc """
  Catppuccin Mocha theme — pastel, warm tones.
  """

  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {205, 214, 244}},
    muted: %Style{fg: {108, 112, 134}},
    subtle: %Style{fg: {69, 71, 90}},
    title: %Style{fg: {137, 180, 250}, modifiers: [:bold]},
    panel: %Style{fg: {205, 214, 244}},
    border: %Style{fg: {108, 112, 134}},
    border_hot: %Style{fg: {137, 180, 250}, modifiers: [:bold]},
    user: %Style{fg: {166, 227, 161}, modifiers: [:bold]},
    assistant: %Style{fg: {205, 214, 244}},
    system: %Style{fg: {108, 112, 134}},
    accent: %Style{fg: {137, 180, 250}, modifiers: [:bold]},
    running: %Style{fg: {249, 226, 175}, modifiers: [:bold]},
    queued: %Style{fg: {203, 166, 247}},
    done: %Style{fg: {166, 227, 161}},
    checkpoint: %Style{fg: {137, 180, 250}},
    error: %Style{fg: {243, 139, 168}, modifiers: [:bold]},
    input: %Style{fg: {205, 214, 244}},
    cursor: %Style{fg: {30, 30, 46}, bg: {137, 180, 250}},
    thinking: %Style{fg: {108, 112, 134}, modifiers: [:dim]},
    status: %Style{fg: {108, 112, 134}},
    status_hot: %Style{fg: {137, 180, 250}, modifiers: [:bold]},
    syntax_keyword: %Style{fg: {137, 180, 250}, modifiers: [:bold]},
    syntax_comment: %Style{fg: {108, 112, 134}, modifiers: [:dim]},
    syntax_string: %Style{fg: {166, 227, 161}},
    syntax_atom: %Style{fg: {203, 166, 247}},
    syntax_number: %Style{fg: {249, 226, 175}},
    syntax_module: %Style{fg: {137, 180, 250}, modifiers: [:bold]},
    syntax_operator: %Style{fg: {137, 180, 250}},
    syntax_default: %Style{fg: {205, 214, 244}}
  }

  def styles, do: @styles
end
