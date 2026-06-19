defmodule Beamcore.TUI.Themes.Volcanic do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 220, 190, 170}},
    muted: %Style{fg: {:rgb, 150, 100, 80}},
    subtle: %Style{fg: {:rgb, 90, 55, 45}},
    title: %Style{fg: {:rgb, 255, 80, 0}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 220, 190, 170}, bg: {:rgb, 25, 12, 8}},
    border: %Style{fg: {:rgb, 200, 60, 0}},
    border_hot: %Style{fg: {:rgb, 255, 120, 0}},
    user: %Style{fg: {:rgb, 255, 160, 60}},
    assistant: %Style{fg: {:rgb, 220, 190, 170}},
    system: %Style{fg: {:rgb, 150, 100, 80}},
    accent: %Style{fg: {:rgb, 255, 80, 0}},
    running: %Style{fg: {:rgb, 255, 200, 60}},
    queued: %Style{fg: {:rgb, 200, 100, 40}},
    done: %Style{fg: {:rgb, 100, 200, 100}},
    checkpoint: %Style{fg: {:rgb, 200, 100, 40}},
    error: %Style{fg: {:rgb, 255, 40, 0}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 220, 190, 170}},
    cursor: %Style{fg: {:rgb, 25, 12, 8}, bg: {:rgb, 255, 80, 0}},
    thinking: %Style{fg: {:rgb, 110, 70, 50}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 150, 100, 80}},
    status_hot: %Style{fg: {:rgb, 255, 120, 0}},
    syntax_keyword: %Style{fg: {:rgb, 255, 80, 0}},
    syntax_comment: %Style{fg: {:rgb, 90, 55, 45}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 255, 200, 60}},
    syntax_atom: %Style{fg: {:rgb, 255, 120, 0}},
    syntax_number: %Style{fg: {:rgb, 255, 160, 60}},
    syntax_module: %Style{fg: {:rgb, 255, 140, 40}},
    syntax_operator: %Style{fg: {:rgb, 170, 120, 100}},
    syntax_default: %Style{fg: {:rgb, 220, 190, 170}},
    code_block: %Style{fg: {:rgb, 255, 160, 60}, bg: {:rgb, 18, 8, 5}},
    code_header: %Style{fg: {:rgb, 200, 60, 0}, bg: {:rgb, 18, 8, 5}}
  }

  def styles, do: @styles
end
