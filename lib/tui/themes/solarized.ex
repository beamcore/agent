defmodule Beamcore.TUI.Themes.Solarized do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 131, 148, 150}},
    muted: %Style{fg: {:rgb, 88, 110, 117}},
    subtle: %Style{fg: {:rgb, 42, 54, 61}},
    title: %Style{fg: {:rgb, 38, 139, 210}},
    panel: %Style{fg: {:rgb, 131, 148, 150}},
    border: %Style{fg: {:rgb, 88, 110, 117}},
    border_hot: %Style{fg: {:rgb, 38, 139, 210}},
    user: %Style{fg: {:rgb, 133, 153, 0}},
    assistant: %Style{fg: {:rgb, 131, 148, 150}},
    system: %Style{fg: {:rgb, 88, 110, 117}},
    accent: %Style{fg: {:rgb, 38, 139, 210}},
    running: %Style{fg: {:rgb, 181, 137, 0}},
    queued: %Style{fg: {:rgb, 108, 113, 196}},
    done: %Style{fg: {:rgb, 133, 153, 0}},
    checkpoint: %Style{fg: {:rgb, 38, 139, 210}},
    error: %Style{fg: {:rgb, 220, 50, 47}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 131, 148, 150}},
    cursor: %Style{fg: {:rgb, 0, 43, 54}, bg: {:rgb, 38, 139, 210}},
    thinking: %Style{fg: {:rgb, 88, 110, 117}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 88, 110, 117}},
    status_hot: %Style{fg: {:rgb, 38, 139, 210}},
    syntax_keyword: %Style{fg: {:rgb, 38, 139, 210}},
    syntax_comment: %Style{fg: {:rgb, 88, 110, 117}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 133, 153, 0}},
    syntax_atom: %Style{fg: {:rgb, 108, 113, 196}},
    syntax_number: %Style{fg: {:rgb, 181, 137, 0}},
    syntax_module: %Style{fg: {:rgb, 38, 139, 210}},
    syntax_operator: %Style{fg: {:rgb, 38, 139, 210}},
    syntax_default: %Style{fg: {:rgb, 131, 148, 150}},
    code_block: %Style{fg: {:rgb, 131, 148, 150}, bg: {:rgb, 0, 43, 54}},
    code_header: %Style{fg: {:rgb, 88, 110, 117}, bg: {:rgb, 0, 43, 54}}
  }

  def styles, do: @styles
end
