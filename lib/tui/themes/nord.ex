defmodule Beamcore.TUI.Themes.Nord do
  @moduledoc """
  Nord theme — arctic, blue-toned palette.
  """

  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {216, 222, 233}},
    muted: %Style{fg: {76, 86, 106}},
    subtle: %Style{fg: {59, 66, 82}},
    title: %Style{fg: {136, 192, 208}, modifiers: [:bold]},
    panel: %Style{fg: {216, 222, 233}},
    border: %Style{fg: {76, 86, 106}},
    border_hot: %Style{fg: {136, 192, 208}, modifiers: [:bold]},
    user: %Style{fg: {163, 190, 140}, modifiers: [:bold]},
    assistant: %Style{fg: {216, 222, 233}},
    system: %Style{fg: {76, 86, 106}},
    accent: %Style{fg: {136, 192, 208}, modifiers: [:bold]},
    running: %Style{fg: {235, 203, 139}, modifiers: [:bold]},
    queued: %Style{fg: {180, 142, 173}},
    done: %Style{fg: {163, 190, 140}},
    checkpoint: %Style{fg: {136, 192, 208}},
    error: %Style{fg: {191, 97, 106}, modifiers: [:bold]},
    input: %Style{fg: {216, 222, 233}},
    cursor: %Style{fg: {46, 52, 64}, bg: {136, 192, 208}},
    thinking: %Style{fg: {76, 86, 106}, modifiers: [:dim]},
    status: %Style{fg: {76, 86, 106}},
    status_hot: %Style{fg: {136, 192, 208}, modifiers: [:bold]},
    syntax_keyword: %Style{fg: {136, 192, 208}, modifiers: [:bold]},
    syntax_comment: %Style{fg: {76, 86, 106}, modifiers: [:dim]},
    syntax_string: %Style{fg: {163, 190, 140}},
    syntax_atom: %Style{fg: {180, 142, 173}},
    syntax_number: %Style{fg: {235, 203, 139}},
    syntax_module: %Style{fg: {136, 192, 208}, modifiers: [:bold]},
    syntax_operator: %Style{fg: {136, 192, 208}},
    syntax_default: %Style{fg: {216, 222, 233}}
  }

  def styles, do: @styles
end
