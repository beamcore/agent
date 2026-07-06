defmodule Beamcore.TUI.Themes.Cyberpunk do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 220, 220, 240}},
    muted: %Style{fg: {:rgb, 100, 100, 140}},
    subtle: %Style{fg: {:rgb, 60, 60, 90}},
    title: %Style{fg: {:rgb, 255, 110, 200}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 200, 200, 220}, bg: {:rgb, 15, 15, 30}},
    border: %Style{fg: {:rgb, 255, 110, 200}},
    border_hot: %Style{fg: {:rgb, 0, 255, 255}},
    user: %Style{fg: {:rgb, 0, 255, 255}},
    assistant: %Style{fg: {:rgb, 220, 220, 240}},
    system: %Style{fg: {:rgb, 100, 100, 140}},
    accent: %Style{fg: {:rgb, 255, 110, 200}},
    running: %Style{fg: {:rgb, 255, 255, 0}},
    queued: %Style{fg: {:rgb, 0, 200, 255}},
    done: %Style{fg: {:rgb, 0, 255, 128}},
    memory: %Style{fg: {:rgb, 0, 200, 255}},
    error: %Style{fg: {:rgb, 255, 50, 50}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 220, 220, 240}},
    cursor: %Style{fg: {:rgb, 15, 15, 30}, bg: {:rgb, 255, 110, 200}},
    thinking: %Style{fg: {:rgb, 100, 100, 140}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 100, 100, 140}},
    status_hot: %Style{fg: {:rgb, 0, 255, 255}},
    syntax_keyword: %Style{fg: {:rgb, 255, 110, 200}},
    syntax_comment: %Style{fg: {:rgb, 80, 80, 120}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 0, 255, 128}},
    syntax_atom: %Style{fg: {:rgb, 0, 255, 255}},
    syntax_number: %Style{fg: {:rgb, 255, 255, 0}},
    syntax_module: %Style{fg: {:rgb, 255, 200, 0}},
    syntax_operator: %Style{fg: {:rgb, 150, 150, 180}},
    syntax_default: %Style{fg: {:rgb, 220, 220, 240}},
    code_block: %Style{fg: {:rgb, 0, 255, 128}, bg: {:rgb, 10, 10, 25}},
    code_header: %Style{fg: {:rgb, 255, 110, 200}, bg: {:rgb, 10, 10, 25}}
  }

  def styles, do: @styles
end
