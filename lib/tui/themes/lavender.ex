defmodule Beamcore.TUI.Themes.Lavender do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 210, 200, 230}},
    muted: %Style{fg: {:rgb, 140, 120, 170}},
    subtle: %Style{fg: {:rgb, 80, 65, 110}},
    title: %Style{fg: {:rgb, 180, 130, 255}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 210, 200, 230}, bg: {:rgb, 20, 16, 30}},
    border: %Style{fg: {:rgb, 140, 100, 220}},
    border_hot: %Style{fg: {:rgb, 180, 130, 255}},
    user: %Style{fg: {:rgb, 200, 160, 255}},
    assistant: %Style{fg: {:rgb, 210, 200, 230}},
    system: %Style{fg: {:rgb, 140, 120, 170}},
    accent: %Style{fg: {:rgb, 180, 130, 255}},
    running: %Style{fg: {:rgb, 220, 180, 255}},
    queued: %Style{fg: {:rgb, 160, 120, 220}},
    done: %Style{fg: {:rgb, 130, 230, 180}},
    memory: %Style{fg: {:rgb, 160, 120, 220}},
    error: %Style{fg: {:rgb, 255, 80, 120}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 210, 200, 230}},
    cursor: %Style{fg: {:rgb, 20, 16, 30}, bg: {:rgb, 180, 130, 255}},
    thinking: %Style{fg: {:rgb, 100, 80, 130}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 140, 120, 170}},
    status_hot: %Style{fg: {:rgb, 200, 160, 255}},
    syntax_keyword: %Style{fg: {:rgb, 180, 130, 255}},
    syntax_comment: %Style{fg: {:rgb, 80, 65, 110}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 255, 180, 220}},
    syntax_atom: %Style{fg: {:rgb, 200, 160, 255}},
    syntax_number: %Style{fg: {:rgb, 160, 200, 255}},
    syntax_module: %Style{fg: {:rgb, 220, 180, 255}},
    syntax_operator: %Style{fg: {:rgb, 160, 140, 190}},
    syntax_default: %Style{fg: {:rgb, 210, 200, 230}},
    code_block: %Style{fg: {:rgb, 200, 160, 255}, bg: {:rgb, 14, 11, 22}},
    code_header: %Style{fg: {:rgb, 140, 100, 220}, bg: {:rgb, 14, 11, 22}}
  }

  def styles, do: @styles
end
