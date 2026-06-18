defmodule Beamcore.TUI.Themes.Melange do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 204, 197, 179}},
    muted: %Style{fg: {:rgb, 128, 123, 110}},
    subtle: %Style{fg: {:rgb, 74, 72, 64}},
    title: %Style{fg: {:rgb, 204, 153, 102}},
    panel: %Style{fg: {:rgb, 204, 197, 179}},
    border: %Style{fg: {:rgb, 128, 123, 110}},
    border_hot: %Style{fg: {:rgb, 204, 153, 102}},
    user: %Style{fg: {:rgb, 153, 187, 116}},
    assistant: %Style{fg: {:rgb, 204, 197, 179}},
    system: %Style{fg: {:rgb, 128, 123, 110}},
    accent: %Style{fg: {:rgb, 204, 153, 102}},
    running: %Style{fg: {:rgb, 230, 180, 90}},
    queued: %Style{fg: {:rgb, 170, 140, 180}},
    done: %Style{fg: {:rgb, 153, 187, 116}},
    checkpoint: %Style{fg: {:rgb, 120, 170, 180}},
    error: %Style{fg: {:rgb, 204, 102, 102}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 204, 197, 179}},
    cursor: %Style{fg: {:rgb, 48, 46, 42}, bg: {:rgb, 204, 153, 102}},
    thinking: %Style{fg: {:rgb, 128, 123, 110}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 128, 123, 110}},
    status_hot: %Style{fg: {:rgb, 204, 153, 102}},
    syntax_keyword: %Style{fg: {:rgb, 170, 140, 180}},
    syntax_comment: %Style{fg: {:rgb, 128, 123, 110}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 153, 187, 116}},
    syntax_atom: %Style{fg: {:rgb, 230, 180, 90}},
    syntax_number: %Style{fg: {:rgb, 230, 180, 90}},
    syntax_module: %Style{fg: {:rgb, 204, 153, 102}},
    syntax_operator: %Style{fg: {:rgb, 170, 140, 180}},
    syntax_default: %Style{fg: {:rgb, 204, 197, 179}},
    code_block: %Style{fg: {:rgb, 204, 197, 179}, bg: {:rgb, 48, 46, 42}},
    code_header: %Style{fg: {:rgb, 128, 123, 110}, bg: {:rgb, 48, 46, 42}}
  }

  def styles, do: @styles
end
