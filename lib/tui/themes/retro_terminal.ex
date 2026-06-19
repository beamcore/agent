defmodule Beamcore.TUI.Themes.RetroTerminal do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 200, 180, 120}},
    muted: %Style{fg: {:rgb, 140, 120, 70}},
    subtle: %Style{fg: {:rgb, 80, 70, 40}},
    title: %Style{fg: {:rgb, 255, 220, 80}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 200, 180, 120}, bg: {:rgb, 20, 18, 10}},
    border: %Style{fg: {:rgb, 180, 160, 80}},
    border_hot: %Style{fg: {:rgb, 255, 220, 80}},
    user: %Style{fg: {:rgb, 255, 220, 80}},
    assistant: %Style{fg: {:rgb, 200, 180, 120}},
    system: %Style{fg: {:rgb, 140, 120, 70}},
    accent: %Style{fg: {:rgb, 255, 220, 80}},
    running: %Style{fg: {:rgb, 255, 240, 150}},
    queued: %Style{fg: {:rgb, 200, 180, 60}},
    done: %Style{fg: {:rgb, 120, 220, 80}},
    checkpoint: %Style{fg: {:rgb, 200, 180, 60}},
    error: %Style{fg: {:rgb, 255, 80, 40}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 200, 180, 120}},
    cursor: %Style{fg: {:rgb, 20, 18, 10}, bg: {:rgb, 255, 220, 80}},
    thinking: %Style{fg: {:rgb, 100, 90, 50}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 140, 120, 70}},
    status_hot: %Style{fg: {:rgb, 255, 220, 80}},
    syntax_keyword: %Style{fg: {:rgb, 255, 220, 80}},
    syntax_comment: %Style{fg: {:rgb, 80, 70, 40}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 180, 220, 80}},
    syntax_atom: %Style{fg: {:rgb, 255, 200, 60}},
    syntax_number: %Style{fg: {:rgb, 220, 200, 100}},
    syntax_module: %Style{fg: {:rgb, 255, 240, 120}},
    syntax_operator: %Style{fg: {:rgb, 160, 140, 90}},
    syntax_default: %Style{fg: {:rgb, 200, 180, 120}},
    code_block: %Style{fg: {:rgb, 180, 220, 80}, bg: {:rgb, 14, 12, 7}},
    code_header: %Style{fg: {:rgb, 180, 160, 80}, bg: {:rgb, 14, 12, 7}}
  }

  def styles, do: @styles
end
