defmodule Beamcore.TUI.Themes.OneDark do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 171, 178, 191}},
    muted: %Style{fg: {:rgb, 92, 99, 112}},
    subtle: %Style{fg: {:rgb, 56, 60, 71}},
    title: %Style{fg: {:rgb, 97, 175, 239}},
    panel: %Style{fg: {:rgb, 171, 178, 191}},
    border: %Style{fg: {:rgb, 92, 99, 112}},
    border_hot: %Style{fg: {:rgb, 97, 175, 239}},
    user: %Style{fg: {:rgb, 152, 195, 121}},
    assistant: %Style{fg: {:rgb, 171, 178, 191}},
    system: %Style{fg: {:rgb, 92, 99, 112}},
    accent: %Style{fg: {:rgb, 97, 175, 239}},
    running: %Style{fg: {:rgb, 229, 192, 123}},
    queued: %Style{fg: {:rgb, 198, 120, 221}},
    done: %Style{fg: {:rgb, 152, 195, 121}},
    checkpoint: %Style{fg: {:rgb, 86, 182, 194}},
    error: %Style{fg: {:rgb, 224, 108, 117}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 171, 178, 191}},
    cursor: %Style{fg: {:rgb, 40, 44, 52}, bg: {:rgb, 97, 175, 239}},
    thinking: %Style{fg: {:rgb, 92, 99, 112}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 92, 99, 112}},
    status_hot: %Style{fg: {:rgb, 97, 175, 239}},
    syntax_keyword: %Style{fg: {:rgb, 198, 120, 221}},
    syntax_comment: %Style{fg: {:rgb, 92, 99, 112}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 152, 195, 121}},
    syntax_atom: %Style{fg: {:rgb, 209, 154, 102}},
    syntax_number: %Style{fg: {:rgb, 209, 154, 102}},
    syntax_module: %Style{fg: {:rgb, 229, 192, 123}},
    syntax_operator: %Style{fg: {:rgb, 198, 120, 221}},
    syntax_default: %Style{fg: {:rgb, 171, 178, 191}},
    code_block: %Style{fg: {:rgb, 171, 178, 191}, bg: {:rgb, 40, 44, 52}},
    code_header: %Style{fg: {:rgb, 92, 99, 112}, bg: {:rgb, 40, 44, 52}}
  }

  def styles, do: @styles
end
