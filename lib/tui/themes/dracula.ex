defmodule Beamcore.TUI.Themes.Dracula do
  @moduledoc """
  Dracula theme — purple/cyan/pink palette on dark background.
  """

  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {248, 248, 242}},
    muted: %Style{fg: {98, 114, 164}},
    subtle: %Style{fg: {68, 71, 90}},
    title: %Style{fg: {255, 121, 198}, modifiers: [:bold]},
    panel: %Style{fg: {248, 248, 242}},
    border: %Style{fg: {98, 114, 164}},
    border_hot: %Style{fg: {139, 233, 253}, modifiers: [:bold]},
    user: %Style{fg: {80, 250, 123}, modifiers: [:bold]},
    assistant: %Style{fg: {248, 248, 242}},
    system: %Style{fg: {98, 114, 164}},
    accent: %Style{fg: {139, 233, 253}, modifiers: [:bold]},
    running: %Style{fg: {241, 250, 140}, modifiers: [:bold]},
    queued: %Style{fg: {189, 147, 249}},
    done: %Style{fg: {80, 250, 123}},
    checkpoint: %Style{fg: {139, 233, 253}},
    error: %Style{fg: {255, 85, 85}, modifiers: [:bold]},
    input: %Style{fg: {248, 248, 242}},
    cursor: %Style{fg: {40, 42, 54}, bg: {139, 233, 253}},
    thinking: %Style{fg: {98, 114, 164}, modifiers: [:dim]},
    status: %Style{fg: {98, 114, 164}},
    status_hot: %Style{fg: {139, 233, 253}, modifiers: [:bold]},
    syntax_keyword: %Style{fg: {255, 121, 198}, modifiers: [:bold]},
    syntax_comment: %Style{fg: {98, 114, 164}, modifiers: [:dim]},
    syntax_string: %Style{fg: {241, 250, 140}},
    syntax_atom: %Style{fg: {189, 147, 249}},
    syntax_number: %Style{fg: {255, 184, 108}},
    syntax_module: %Style{fg: {139, 233, 253}, modifiers: [:bold]},
    syntax_operator: %Style{fg: {255, 121, 198}},
    syntax_default: %Style{fg: {248, 248, 242}}
  }

  def styles, do: @styles
end
