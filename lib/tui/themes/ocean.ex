defmodule Beamcore.TUI.Themes.Ocean do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 190, 210, 230}},
    muted: %Style{fg: {:rgb, 100, 130, 160}},
    subtle: %Style{fg: {:rgb, 60, 80, 100}},
    title: %Style{fg: {:rgb, 0, 180, 220}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 190, 210, 230}, bg: {:rgb, 12, 20, 30}},
    border: %Style{fg: {:rgb, 0, 150, 200}},
    border_hot: %Style{fg: {:rgb, 0, 220, 255}},
    user: %Style{fg: {:rgb, 0, 200, 255}},
    assistant: %Style{fg: {:rgb, 190, 210, 230}},
    system: %Style{fg: {:rgb, 100, 130, 160}},
    accent: %Style{fg: {:rgb, 0, 180, 220}},
    running: %Style{fg: {:rgb, 100, 220, 255}},
    queued: %Style{fg: {:rgb, 0, 140, 180}},
    done: %Style{fg: {:rgb, 0, 200, 150}},
    memory: %Style{fg: {:rgb, 0, 140, 180}},
    error: %Style{fg: {:rgb, 255, 80, 80}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 190, 210, 230}},
    cursor: %Style{fg: {:rgb, 12, 20, 30}, bg: {:rgb, 0, 180, 220}},
    thinking: %Style{fg: {:rgb, 70, 100, 130}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 100, 130, 160}},
    status_hot: %Style{fg: {:rgb, 0, 200, 255}},
    syntax_keyword: %Style{fg: {:rgb, 0, 180, 220}},
    syntax_comment: %Style{fg: {:rgb, 60, 80, 100}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 0, 200, 150}},
    syntax_atom: %Style{fg: {:rgb, 0, 220, 255}},
    syntax_number: %Style{fg: {:rgb, 100, 200, 255}},
    syntax_module: %Style{fg: {:rgb, 0, 160, 200}},
    syntax_operator: %Style{fg: {:rgb, 120, 150, 180}},
    syntax_default: %Style{fg: {:rgb, 190, 210, 230}},
    code_block: %Style{fg: {:rgb, 0, 220, 200}, bg: {:rgb, 8, 15, 22}},
    code_header: %Style{fg: {:rgb, 0, 150, 200}, bg: {:rgb, 8, 15, 22}}
  }

  def styles, do: @styles
end
