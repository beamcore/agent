defmodule Beamcore.TUI.Themes.Arctic do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 220, 230, 245}},
    muted: %Style{fg: {:rgb, 140, 160, 190}},
    subtle: %Style{fg: {:rgb, 80, 100, 130}},
    title: %Style{fg: {:rgb, 180, 220, 255}, modifiers: [:bold]},
    panel: %Style{fg: {:rgb, 220, 230, 245}, bg: {:rgb, 18, 22, 32}},
    border: %Style{fg: {:rgb, 100, 160, 220}},
    border_hot: %Style{fg: {:rgb, 180, 220, 255}},
    user: %Style{fg: {:rgb, 100, 200, 255}},
    assistant: %Style{fg: {:rgb, 220, 230, 245}},
    system: %Style{fg: {:rgb, 140, 160, 190}},
    accent: %Style{fg: {:rgb, 180, 220, 255}},
    running: %Style{fg: {:rgb, 200, 230, 255}},
    queued: %Style{fg: {:rgb, 100, 180, 240}},
    done: %Style{fg: {:rgb, 100, 240, 200}},
    checkpoint: %Style{fg: {:rgb, 100, 180, 240}},
    error: %Style{fg: {:rgb, 255, 100, 100}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 220, 230, 245}},
    cursor: %Style{fg: {:rgb, 18, 22, 32}, bg: {:rgb, 180, 220, 255}},
    thinking: %Style{fg: {:rgb, 100, 120, 150}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 140, 160, 190}},
    status_hot: %Style{fg: {:rgb, 100, 200, 255}},
    syntax_keyword: %Style{fg: {:rgb, 180, 220, 255}},
    syntax_comment: %Style{fg: {:rgb, 80, 100, 130}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 100, 240, 200}},
    syntax_atom: %Style{fg: {:rgb, 100, 200, 255}},
    syntax_number: %Style{fg: {:rgb, 200, 220, 255}},
    syntax_module: %Style{fg: {:rgb, 150, 200, 255}},
    syntax_operator: %Style{fg: {:rgb, 150, 170, 200}},
    syntax_default: %Style{fg: {:rgb, 220, 230, 245}},
    code_block: %Style{fg: {:rgb, 100, 220, 255}, bg: {:rgb, 12, 16, 24}},
    code_header: %Style{fg: {:rgb, 100, 160, 220}, bg: {:rgb, 12, 16, 24}}
  }

  def styles, do: @styles
end
