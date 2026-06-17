defmodule Beamcore.TUI.Themes.Solarized do
  @moduledoc """
  Solarized theme — warm, balanced palette.
  """

  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {131, 148, 150}},
    muted: %Style{fg: {88, 110, 117}},
    subtle: %Style{fg: {42, 54, 61}},
    title: %Style{fg: {38, 139, 210}, modifiers: [:bold]},
    panel: %Style{fg: {131, 148, 150}},
    border: %Style{fg: {88, 110, 117}},
    border_hot: %Style{fg: {38, 139, 210}, modifiers: [:bold]},
    user: %Style{fg: {133, 153, 0}, modifiers: [:bold]},
    assistant: %Style{fg: {131, 148, 150}},
    system: %Style{fg: {88, 110, 117}},
    accent: %Style{fg: {38, 139, 210}, modifiers: [:bold]},
    running: %Style{fg: {181, 137, 0}, modifiers: [:bold]},
    queued: %Style{fg: {108, 113, 196}},
    done: %Style{fg: {133, 153, 0}},
    checkpoint: %Style{fg: {38, 139, 210}},
    error: %Style{fg: {220, 50, 47}, modifiers: [:bold]},
    input: %Style{fg: {131, 148, 150}},
    cursor: %Style{fg: {0, 43, 54}, bg: {38, 139, 210}},
    thinking: %Style{fg: {88, 110, 117}, modifiers: [:dim]},
    status: %Style{fg: {88, 110, 117}},
    status_hot: %Style{fg: {38, 139, 210}, modifiers: [:bold]},
    syntax_keyword: %Style{fg: {38, 139, 210}, modifiers: [:bold]},
    syntax_comment: %Style{fg: {88, 110, 117}, modifiers: [:dim]},
    syntax_string: %Style{fg: {133, 153, 0}},
    syntax_atom: %Style{fg: {108, 113, 196}},
    syntax_number: %Style{fg: {181, 137, 0}},
    syntax_module: %Style{fg: {38, 139, 210}, modifiers: [:bold]},
    syntax_operator: %Style{fg: {38, 139, 210}},
    syntax_default: %Style{fg: {131, 148, 150}}
  }

  def styles, do: @styles
end
