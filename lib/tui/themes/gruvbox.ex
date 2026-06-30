defmodule Beamcore.TUI.Themes.Gruvbox do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 235, 219, 178}},
    muted: %Style{fg: {:rgb, 146, 131, 116}},
    subtle: %Style{fg: {:rgb, 80, 73, 69}},
    title: %Style{fg: {:rgb, 250, 189, 47}},
    panel: %Style{fg: {:rgb, 235, 219, 178}},
    border: %Style{fg: {:rgb, 146, 131, 116}},
    border_hot: %Style{fg: {:rgb, 250, 189, 47}},
    user: %Style{fg: {:rgb, 184, 187, 38}},
    assistant: %Style{fg: {:rgb, 235, 219, 178}},
    system: %Style{fg: {:rgb, 146, 131, 116}},
    accent: %Style{fg: {:rgb, 250, 189, 47}},
    running: %Style{fg: {:rgb, 254, 128, 25}},
    queued: %Style{fg: {:rgb, 211, 134, 155}},
    done: %Style{fg: {:rgb, 184, 187, 38}},
    memory: %Style{fg: {:rgb, 131, 165, 152}},
    error: %Style{fg: {:rgb, 251, 73, 52}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 235, 219, 178}},
    cursor: %Style{fg: {:rgb, 40, 40, 40}, bg: {:rgb, 250, 189, 47}},
    thinking: %Style{fg: {:rgb, 146, 131, 116}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 146, 131, 116}},
    status_hot: %Style{fg: {:rgb, 250, 189, 47}},
    syntax_keyword: %Style{fg: {:rgb, 254, 128, 25}},
    syntax_comment: %Style{fg: {:rgb, 146, 131, 116}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 184, 187, 38}},
    syntax_atom: %Style{fg: {:rgb, 211, 134, 155}},
    syntax_number: %Style{fg: {:rgb, 211, 134, 155}},
    syntax_module: %Style{fg: {:rgb, 250, 189, 47}},
    syntax_operator: %Style{fg: {:rgb, 250, 189, 47}},
    syntax_default: %Style{fg: {:rgb, 235, 219, 178}},
    code_block: %Style{fg: {:rgb, 235, 219, 178}, bg: {:rgb, 40, 40, 40}},
    code_header: %Style{fg: {:rgb, 146, 131, 116}, bg: {:rgb, 40, 40, 40}}
  }

  def styles, do: @styles
end
