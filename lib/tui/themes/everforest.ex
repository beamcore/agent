defmodule Beamcore.TUI.Themes.Everforest do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 211, 198, 170}},
    muted: %Style{fg: {:rgb, 133, 128, 116}},
    subtle: %Style{fg: {:rgb, 84, 82, 74}},
    title: %Style{fg: {:rgb, 167, 192, 128}},
    panel: %Style{fg: {:rgb, 211, 198, 170}},
    border: %Style{fg: {:rgb, 133, 128, 116}},
    border_hot: %Style{fg: {:rgb, 167, 192, 128}},
    user: %Style{fg: {:rgb, 167, 192, 128}},
    assistant: %Style{fg: {:rgb, 211, 198, 170}},
    system: %Style{fg: {:rgb, 133, 128, 116}},
    accent: %Style{fg: {:rgb, 127, 187, 179}},
    running: %Style{fg: {:rgb, 230, 180, 90}},
    queued: %Style{fg: {:rgb, 214, 153, 170}},
    done: %Style{fg: {:rgb, 167, 192, 128}},
    memory: %Style{fg: {:rgb, 127, 187, 179}},
    error: %Style{fg: {:rgb, 230, 126, 128}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 211, 198, 170}},
    cursor: %Style{fg: {:rgb, 54, 56, 50}, bg: {:rgb, 167, 192, 128}},
    thinking: %Style{fg: {:rgb, 133, 128, 116}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 133, 128, 116}},
    status_hot: %Style{fg: {:rgb, 127, 187, 179}},
    syntax_keyword: %Style{fg: {:rgb, 214, 153, 170}},
    syntax_comment: %Style{fg: {:rgb, 133, 128, 116}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 167, 192, 128}},
    syntax_atom: %Style{fg: {:rgb, 230, 180, 90}},
    syntax_number: %Style{fg: {:rgb, 230, 180, 90}},
    syntax_module: %Style{fg: {:rgb, 127, 187, 179}},
    syntax_operator: %Style{fg: {:rgb, 214, 153, 170}},
    syntax_default: %Style{fg: {:rgb, 211, 198, 170}},
    code_block: %Style{fg: {:rgb, 211, 198, 170}, bg: {:rgb, 54, 56, 50}},
    code_header: %Style{fg: {:rgb, 133, 128, 116}, bg: {:rgb, 54, 56, 50}}
  }

  def styles, do: @styles
end
