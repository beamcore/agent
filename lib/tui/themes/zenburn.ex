defmodule Beamcore.TUI.Themes.Zenburn do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 220, 220, 204}},
    muted: %Style{fg: {:rgb, 136, 136, 120}},
    subtle: %Style{fg: {:rgb, 76, 76, 68}},
    title: %Style{fg: {:rgb, 204, 170, 136}},
    panel: %Style{fg: {:rgb, 220, 220, 204}},
    border: %Style{fg: {:rgb, 136, 136, 120}},
    border_hot: %Style{fg: {:rgb, 204, 170, 136}},
    user: %Style{fg: {:rgb, 204, 204, 170}},
    assistant: %Style{fg: {:rgb, 220, 220, 204}},
    system: %Style{fg: {:rgb, 136, 136, 120}},
    accent: %Style{fg: {:rgb, 204, 170, 136}},
    running: %Style{fg: {:rgb, 220, 170, 102}},
    queued: %Style{fg: {:rgb, 170, 170, 204}},
    done: %Style{fg: {:rgb, 170, 204, 136}},
    checkpoint: %Style{fg: {:rgb, 136, 204, 204}},
    error: %Style{fg: {:rgb, 204, 102, 102}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 220, 220, 204}},
    cursor: %Style{fg: {:rgb, 50, 50, 45}, bg: {:rgb, 204, 170, 136}},
    thinking: %Style{fg: {:rgb, 136, 136, 120}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 136, 136, 120}},
    status_hot: %Style{fg: {:rgb, 204, 170, 136}},
    syntax_keyword: %Style{fg: {:rgb, 220, 170, 102}},
    syntax_comment: %Style{fg: {:rgb, 136, 136, 120}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 170, 204, 136}},
    syntax_atom: %Style{fg: {:rgb, 170, 170, 204}},
    syntax_number: %Style{fg: {:rgb, 136, 204, 204}},
    syntax_module: %Style{fg: {:rgb, 204, 170, 136}},
    syntax_operator: %Style{fg: {:rgb, 220, 170, 102}},
    syntax_default: %Style{fg: {:rgb, 220, 220, 204}},
    code_block: %Style{fg: {:rgb, 220, 220, 204}, bg: {:rgb, 50, 50, 45}},
    code_header: %Style{fg: {:rgb, 136, 136, 120}, bg: {:rgb, 50, 50, 45}}
  }

  def styles, do: @styles
end
