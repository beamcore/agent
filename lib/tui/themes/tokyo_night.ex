defmodule Beamcore.TUI.Themes.TokyoNight do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 192, 202, 245}},
    muted: %Style{fg: {:rgb, 86, 95, 137}},
    subtle: %Style{fg: {:rgb, 54, 62, 92}},
    title: %Style{fg: {:rgb, 122, 162, 247}},
    panel: %Style{fg: {:rgb, 192, 202, 245}},
    border: %Style{fg: {:rgb, 86, 95, 137}},
    border_hot: %Style{fg: {:rgb, 122, 162, 247}},
    user: %Style{fg: {:rgb, 158, 206, 106}},
    assistant: %Style{fg: {:rgb, 192, 202, 245}},
    system: %Style{fg: {:rgb, 86, 95, 137}},
    accent: %Style{fg: {:rgb, 122, 162, 247}},
    running: %Style{fg: {:rgb, 224, 175, 104}},
    queued: %Style{fg: {:rgb, 187, 154, 247}},
    done: %Style{fg: {:rgb, 158, 206, 106}},
    checkpoint: %Style{fg: {:rgb, 122, 162, 247}},
    error: %Style{fg: {:rgb, 247, 118, 142}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 192, 202, 245}},
    cursor: %Style{fg: {:rgb, 26, 27, 46}, bg: {:rgb, 122, 162, 247}},
    thinking: %Style{fg: {:rgb, 86, 95, 137}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 86, 95, 137}},
    status_hot: %Style{fg: {:rgb, 122, 162, 247}},
    syntax_keyword: %Style{fg: {:rgb, 122, 162, 247}},
    syntax_comment: %Style{fg: {:rgb, 86, 95, 137}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 158, 206, 106}},
    syntax_atom: %Style{fg: {:rgb, 187, 154, 247}},
    syntax_number: %Style{fg: {:rgb, 224, 175, 104}},
    syntax_module: %Style{fg: {:rgb, 122, 162, 247}},
    syntax_operator: %Style{fg: {:rgb, 122, 162, 247}},
    syntax_default: %Style{fg: {:rgb, 192, 202, 245}}
  }

  def styles, do: @styles
end
