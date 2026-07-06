defmodule Beamcore.TUI.Themes.Forest do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 190, 210, 180}},
    muted: %Style{fg: {:rgb, 120, 150, 110}},
    subtle: %Style{fg: {:rgb, 70, 90, 60}},
    title: %Style{fg: {:rgb, 80, 200, 80}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 190, 210, 180}, bg: {:rgb, 15, 22, 14}},
    border: %Style{fg: {:rgb, 60, 160, 60}},
    border_hot: %Style{fg: {:rgb, 80, 200, 80}},
    user: %Style{fg: {:rgb, 140, 220, 100}},
    assistant: %Style{fg: {:rgb, 190, 210, 180}},
    system: %Style{fg: {:rgb, 120, 150, 110}},
    accent: %Style{fg: {:rgb, 80, 200, 80}},
    running: %Style{fg: {:rgb, 200, 240, 140}},
    queued: %Style{fg: {:rgb, 100, 180, 80}},
    done: %Style{fg: {:rgb, 60, 200, 120}},
    memory: %Style{fg: {:rgb, 100, 180, 80}},
    error: %Style{fg: {:rgb, 220, 60, 40}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 190, 210, 180}},
    cursor: %Style{fg: {:rgb, 15, 22, 14}, bg: {:rgb, 80, 200, 80}},
    thinking: %Style{fg: {:rgb, 80, 110, 70}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 120, 150, 110}},
    status_hot: %Style{fg: {:rgb, 140, 220, 100}},
    syntax_keyword: %Style{fg: {:rgb, 80, 200, 80}},
    syntax_comment: %Style{fg: {:rgb, 70, 90, 60}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 200, 240, 140}},
    syntax_atom: %Style{fg: {:rgb, 140, 220, 100}},
    syntax_number: %Style{fg: {:rgb, 60, 180, 120}},
    syntax_module: %Style{fg: {:rgb, 100, 200, 80}},
    syntax_operator: %Style{fg: {:rgb, 140, 160, 130}},
    syntax_default: %Style{fg: {:rgb, 190, 210, 180}},
    code_block: %Style{fg: {:rgb, 140, 220, 100}, bg: {:rgb, 10, 16, 10}},
    code_header: %Style{fg: {:rgb, 60, 160, 60}, bg: {:rgb, 10, 16, 10}}
  }

  def styles, do: @styles
end
