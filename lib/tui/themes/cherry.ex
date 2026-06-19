defmodule Beamcore.TUI.Themes.Cherry do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 230, 200, 210}},
    muted: %Style{fg: {:rgb, 160, 110, 130}},
    subtle: %Style{fg: {:rgb, 100, 60, 80}},
    title: %Style{fg: {:rgb, 255, 60, 100}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 230, 200, 210}, bg: {:rgb, 25, 15, 20}},
    border: %Style{fg: {:rgb, 200, 50, 80}},
    border_hot: %Style{fg: {:rgb, 255, 60, 100}},
    user: %Style{fg: {:rgb, 255, 120, 150}},
    assistant: %Style{fg: {:rgb, 230, 200, 210}},
    system: %Style{fg: {:rgb, 160, 110, 130}},
    accent: %Style{fg: {:rgb, 255, 60, 100}},
    running: %Style{fg: {:rgb, 255, 150, 180}},
    queued: %Style{fg: {:rgb, 200, 80, 120}},
    done: %Style{fg: {:rgb, 100, 220, 150}},
    checkpoint: %Style{fg: {:rgb, 200, 80, 120}},
    error: %Style{fg: {:rgb, 255, 40, 40}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 230, 200, 210}},
    cursor: %Style{fg: {:rgb, 25, 15, 20}, bg: {:rgb, 255, 60, 100}},
    thinking: %Style{fg: {:rgb, 120, 80, 100}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 160, 110, 130}},
    status_hot: %Style{fg: {:rgb, 255, 120, 150}},
    syntax_keyword: %Style{fg: {:rgb, 255, 60, 100}},
    syntax_comment: %Style{fg: {:rgb, 100, 60, 80}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 255, 180, 200}},
    syntax_atom: %Style{fg: {:rgb, 255, 120, 150}},
    syntax_number: %Style{fg: {:rgb, 200, 100, 140}},
    syntax_module: %Style{fg: {:rgb, 255, 150, 180}},
    syntax_operator: %Style{fg: {:rgb, 180, 140, 160}},
    syntax_default: %Style{fg: {:rgb, 230, 200, 210}},
    code_block: %Style{fg: {:rgb, 255, 150, 180}, bg: {:rgb, 18, 10, 14}},
    code_header: %Style{fg: {:rgb, 200, 50, 80}, bg: {:rgb, 18, 10, 14}}
  }

  def styles, do: @styles
end
