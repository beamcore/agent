defmodule Beamcore.TUI.Themes.Nord do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 216, 222, 233}},
    muted: %Style{fg: {:rgb, 76, 86, 106}},
    subtle: %Style{fg: {:rgb, 59, 66, 82}},
    title: %Style{fg: {:rgb, 136, 192, 208}},
    panel: %Style{fg: {:rgb, 216, 222, 233}},
    border: %Style{fg: {:rgb, 76, 86, 106}},
    border_hot: %Style{fg: {:rgb, 136, 192, 208}},
    user: %Style{fg: {:rgb, 163, 190, 140}},
    assistant: %Style{fg: {:rgb, 216, 222, 233}},
    system: %Style{fg: {:rgb, 76, 86, 106}},
    accent: %Style{fg: {:rgb, 136, 192, 208}},
    running: %Style{fg: {:rgb, 235, 203, 139}},
    queued: %Style{fg: {:rgb, 180, 142, 173}},
    done: %Style{fg: {:rgb, 163, 190, 140}},
    checkpoint: %Style{fg: {:rgb, 136, 192, 208}},
    error: %Style{fg: {:rgb, 191, 97, 106}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 216, 222, 233}},
    cursor: %Style{fg: {:rgb, 46, 52, 64}, bg: {:rgb, 136, 192, 208}},
    thinking: %Style{fg: {:rgb, 76, 86, 106}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 76, 86, 106}},
    status_hot: %Style{fg: {:rgb, 136, 192, 208}},
    syntax_keyword: %Style{fg: {:rgb, 136, 192, 208}},
    syntax_comment: %Style{fg: {:rgb, 76, 86, 106}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 163, 190, 140}},
    syntax_atom: %Style{fg: {:rgb, 180, 142, 173}},
    syntax_number: %Style{fg: {:rgb, 235, 203, 139}},
    syntax_module: %Style{fg: {:rgb, 136, 192, 208}},
    syntax_operator: %Style{fg: {:rgb, 136, 192, 208}},
    syntax_default: %Style{fg: {:rgb, 216, 222, 233}},
    code_block: %Style{fg: {:rgb, 216, 222, 233}, bg: {:rgb, 46, 52, 64}},
    code_header: %Style{fg: {:rgb, 76, 86, 106}, bg: {:rgb, 46, 52, 64}}
  }

  def styles, do: @styles
end
