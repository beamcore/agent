defmodule Beamcore.TUI.Themes.Sunset do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 230, 200, 180}},
    muted: %Style{fg: {:rgb, 160, 120, 100}},
    subtle: %Style{fg: {:rgb, 100, 70, 60}},
    title: %Style{fg: {:rgb, 255, 140, 50}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 230, 200, 180}, bg: {:rgb, 30, 20, 25}},
    border: %Style{fg: {:rgb, 255, 100, 60}},
    border_hot: %Style{fg: {:rgb, 255, 180, 50}},
    user: %Style{fg: {:rgb, 255, 180, 50}},
    assistant: %Style{fg: {:rgb, 230, 200, 180}},
    system: %Style{fg: {:rgb, 160, 120, 100}},
    accent: %Style{fg: {:rgb, 255, 100, 60}},
    running: %Style{fg: {:rgb, 255, 200, 80}},
    queued: %Style{fg: {:rgb, 200, 120, 80}},
    done: %Style{fg: {:rgb, 120, 200, 100}},
    memory: %Style{fg: {:rgb, 200, 120, 80}},
    error: %Style{fg: {:rgb, 255, 60, 40}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 230, 200, 180}},
    cursor: %Style{fg: {:rgb, 30, 20, 25}, bg: {:rgb, 255, 140, 50}},
    thinking: %Style{fg: {:rgb, 120, 90, 70}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 160, 120, 100}},
    status_hot: %Style{fg: {:rgb, 255, 140, 50}},
    syntax_keyword: %Style{fg: {:rgb, 255, 100, 60}},
    syntax_comment: %Style{fg: {:rgb, 100, 70, 60}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 255, 200, 80}},
    syntax_atom: %Style{fg: {:rgb, 255, 140, 50}},
    syntax_number: %Style{fg: {:rgb, 200, 120, 80}},
    syntax_module: %Style{fg: {:rgb, 255, 180, 100}},
    syntax_operator: %Style{fg: {:rgb, 180, 140, 120}},
    syntax_default: %Style{fg: {:rgb, 230, 200, 180}},
    code_block: %Style{fg: {:rgb, 255, 200, 80}, bg: {:rgb, 20, 15, 18}},
    code_header: %Style{fg: {:rgb, 255, 100, 60}, bg: {:rgb, 20, 15, 18}}
  }

  def styles, do: @styles
end
