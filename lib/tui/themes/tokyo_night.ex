defmodule Beamcore.TUI.Themes.TokyoNight do
  @moduledoc """
  Tokyo Night theme — cool blue/purple palette.
  """

  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {192, 202, 245}},
    muted: %Style{fg: {86, 95, 137}},
    subtle: %Style{fg: {54, 62, 92}},
    title: %Style{fg: {122, 162, 247}, modifiers: [:bold]},
    panel: %Style{fg: {192, 202, 245}},
    border: %Style{fg: {86, 95, 137}},
    border_hot: %Style{fg: {122, 162, 247}, modifiers: [:bold]},
    user: %Style{fg: {158, 206, 106}, modifiers: [:bold]},
    assistant: %Style{fg: {192, 202, 245}},
    system: %Style{fg: {86, 95, 137}},
    accent: %Style{fg: {122, 162, 247}, modifiers: [:bold]},
    running: %Style{fg: {224, 175, 104}, modifiers: [:bold]},
    queued: %Style{fg: {187, 154, 247}},
    done: %Style{fg: {158, 206, 106}},
    checkpoint: %Style{fg: {122, 162, 247}},
    error: %Style{fg: {247, 118, 142}, modifiers: [:bold]},
    input: %Style{fg: {192, 202, 245}},
    cursor: %Style{fg: {26, 27, 46}, bg: {122, 162, 247}},
    thinking: %Style{fg: {86, 95, 137}, modifiers: [:dim]},
    status: %Style{fg: {86, 95, 137}},
    status_hot: %Style{fg: {122, 162, 247}, modifiers: [:bold]},
    syntax_keyword: %Style{fg: {122, 162, 247}, modifiers: [:bold]},
    syntax_comment: %Style{fg: {86, 95, 137}, modifiers: [:dim]},
    syntax_string: %Style{fg: {158, 206, 106}},
    syntax_atom: %Style{fg: {187, 154, 247}},
    syntax_number: %Style{fg: {224, 175, 104}},
    syntax_module: %Style{fg: {122, 162, 247}, modifiers: [:bold]},
    syntax_operator: %Style{fg: {122, 162, 247}},
    syntax_default: %Style{fg: {192, 202, 245}}
  }

  def styles, do: @styles
end
