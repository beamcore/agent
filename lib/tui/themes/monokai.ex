defmodule Beamcore.TUI.Themes.Monokai do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 248, 248, 242}},
    muted: %Style{fg: {:rgb, 117, 113, 94}},
    subtle: %Style{fg: {:rgb, 73, 72, 62}},
    title: %Style{fg: {:rgb, 166, 226, 46}},
    panel: %Style{fg: {:rgb, 248, 248, 242}},
    border: %Style{fg: {:rgb, 117, 113, 94}},
    border_hot: %Style{fg: {:rgb, 166, 226, 46}},
    user: %Style{fg: {:rgb, 166, 226, 46}},
    assistant: %Style{fg: {:rgb, 248, 248, 242}},
    system: %Style{fg: {:rgb, 117, 113, 94}},
    accent: %Style{fg: {:rgb, 102, 217, 239}},
    running: %Style{fg: {:rgb, 253, 151, 31}},
    queued: %Style{fg: {:rgb, 174, 129, 255}},
    done: %Style{fg: {:rgb, 166, 226, 46}},
    memory: %Style{fg: {:rgb, 102, 217, 239}},
    error: %Style{fg: {:rgb, 249, 38, 114}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 248, 248, 242}},
    cursor: %Style{fg: {:rgb, 39, 40, 34}, bg: {:rgb, 248, 248, 242}},
    thinking: %Style{fg: {:rgb, 117, 113, 94}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 117, 113, 94}},
    status_hot: %Style{fg: {:rgb, 102, 217, 239}},
    syntax_keyword: %Style{fg: {:rgb, 249, 38, 114}},
    syntax_comment: %Style{fg: {:rgb, 117, 113, 94}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 230, 219, 116}},
    syntax_atom: %Style{fg: {:rgb, 174, 129, 255}},
    syntax_number: %Style{fg: {:rgb, 174, 129, 255}},
    syntax_module: %Style{fg: {:rgb, 102, 217, 239}},
    syntax_operator: %Style{fg: {:rgb, 249, 38, 114}},
    syntax_default: %Style{fg: {:rgb, 248, 248, 242}},
    code_block: %Style{fg: {:rgb, 248, 248, 242}, bg: {:rgb, 39, 40, 34}},
    code_header: %Style{fg: {:rgb, 117, 113, 94}, bg: {:rgb, 39, 40, 34}}
  }

  def styles, do: @styles
end
