defmodule Beamcore.TUI.Themes.Palenight do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 166, 172, 205}},
    muted: %Style{fg: {:rgb, 88, 93, 120}},
    subtle: %Style{fg: {:rgb, 55, 59, 83}},
    title: %Style{fg: {:rgb, 130, 170, 255}},
    panel: %Style{fg: {:rgb, 166, 172, 205}},
    border: %Style{fg: {:rgb, 88, 93, 120}},
    border_hot: %Style{fg: {:rgb, 130, 170, 255}},
    user: %Style{fg: {:rgb, 195, 232, 141}},
    assistant: %Style{fg: {:rgb, 166, 172, 205}},
    system: %Style{fg: {:rgb, 88, 93, 120}},
    accent: %Style{fg: {:rgb, 130, 170, 255}},
    running: %Style{fg: {:rgb, 255, 203, 107}},
    queued: %Style{fg: {:rgb, 199, 146, 234}},
    done: %Style{fg: {:rgb, 195, 232, 141}},
    checkpoint: %Style{fg: {:rgb, 130, 170, 255}},
    error: %Style{fg: {:rgb, 224, 108, 117}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 166, 172, 205}},
    cursor: %Style{fg: {:rgb, 35, 38, 52}, bg: {:rgb, 130, 170, 255}},
    thinking: %Style{fg: {:rgb, 88, 93, 120}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 88, 93, 120}},
    status_hot: %Style{fg: {:rgb, 130, 170, 255}},
    syntax_keyword: %Style{fg: {:rgb, 199, 146, 234}},
    syntax_comment: %Style{fg: {:rgb, 88, 93, 120}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 195, 232, 141}},
    syntax_atom: %Style{fg: {:rgb, 255, 203, 107}},
    syntax_number: %Style{fg: {:rgb, 255, 203, 107}},
    syntax_module: %Style{fg: {:rgb, 130, 170, 255}},
    syntax_operator: %Style{fg: {:rgb, 199, 146, 234}},
    syntax_default: %Style{fg: {:rgb, 166, 172, 205}}
  }

  def styles, do: @styles
end
