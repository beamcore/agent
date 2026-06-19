defmodule Beamcore.TUI.Themes.Matrix do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 0, 255, 65}},
    muted: %Style{fg: {:rgb, 0, 140, 40}},
    subtle: %Style{fg: {:rgb, 0, 60, 20}},
    title: %Style{fg: {:rgb, 0, 255, 65}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 0, 255, 65}, bg: {:rgb, 0, 10, 0}},
    border: %Style{fg: {:rgb, 0, 180, 50}},
    border_hot: %Style{fg: {:rgb, 0, 255, 65}},
    user: %Style{fg: {:rgb, 180, 255, 180}},
    assistant: %Style{fg: {:rgb, 0, 255, 65}},
    system: %Style{fg: {:rgb, 0, 140, 40}},
    accent: %Style{fg: {:rgb, 0, 255, 65}, modifiers: [:bold]},
    running: %Style{fg: {:rgb, 200, 255, 200}},
    queued: %Style{fg: {:rgb, 0, 200, 50}},
    done: %Style{fg: {:rgb, 0, 255, 65}},
    checkpoint: %Style{fg: {:rgb, 0, 200, 50}},
    error: %Style{fg: {:rgb, 255, 0, 0}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 0, 255, 65}},
    cursor: %Style{fg: {:rgb, 0, 10, 0}, bg: {:rgb, 0, 255, 65}},
    thinking: %Style{fg: {:rgb, 0, 100, 30}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 0, 140, 40}},
    status_hot: %Style{fg: {:rgb, 0, 255, 65}},
    syntax_keyword: %Style{fg: {:rgb, 0, 255, 65}, modifiers: [:bold]},
    syntax_comment: %Style{fg: {:rgb, 0, 80, 25}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 180, 255, 180}},
    syntax_atom: %Style{fg: {:rgb, 0, 220, 55}},
    syntax_number: %Style{fg: {:rgb, 200, 255, 200}},
    syntax_module: %Style{fg: {:rgb, 0, 200, 50}},
    syntax_operator: %Style{fg: {:rgb, 0, 160, 45}},
    syntax_default: %Style{fg: {:rgb, 0, 255, 65}},
    code_block: %Style{fg: {:rgb, 0, 255, 65}, bg: {:rgb, 0, 5, 0}},
    code_header: %Style{fg: {:rgb, 0, 180, 50}, bg: {:rgb, 0, 5, 0}}
  }

  def styles, do: @styles
end
