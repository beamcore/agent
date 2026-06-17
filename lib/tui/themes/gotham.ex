defmodule Beamcore.TUI.Themes.Gotham do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 152, 187, 187}},
    muted: %Style{fg: {:rgb, 80, 102, 104}},
    subtle: %Style{fg: {:rgb, 49, 64, 66}},
    title: %Style{fg: {:rgb, 87, 214, 214}},
    panel: %Style{fg: {:rgb, 152, 187, 187}},
    border: %Style{fg: {:rgb, 80, 102, 104}},
    border_hot: %Style{fg: {:rgb, 87, 214, 214}},
    user: %Style{fg: {:rgb, 87, 214, 214}},
    assistant: %Style{fg: {:rgb, 152, 187, 187}},
    system: %Style{fg: {:rgb, 80, 102, 104}},
    accent: %Style{fg: {:rgb, 87, 214, 214}},
    running: %Style{fg: {:rgb, 214, 181, 90}},
    queued: %Style{fg: {:rgb, 155, 130, 185}},
    done: %Style{fg: {:rgb, 87, 214, 175}},
    checkpoint: %Style{fg: {:rgb, 87, 214, 214}},
    error: %Style{fg: {:rgb, 214, 90, 90}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 152, 187, 187}},
    cursor: %Style{fg: {:rgb, 22, 30, 33}, bg: {:rgb, 87, 214, 214}},
    thinking: %Style{fg: {:rgb, 80, 102, 104}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 80, 102, 104}},
    status_hot: %Style{fg: {:rgb, 87, 214, 214}},
    syntax_keyword: %Style{fg: {:rgb, 155, 130, 185}},
    syntax_comment: %Style{fg: {:rgb, 80, 102, 104}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 87, 214, 175}},
    syntax_atom: %Style{fg: {:rgb, 214, 181, 90}},
    syntax_number: %Style{fg: {:rgb, 214, 181, 90}},
    syntax_module: %Style{fg: {:rgb, 87, 214, 214}},
    syntax_operator: %Style{fg: {:rgb, 155, 130, 185}},
    syntax_default: %Style{fg: {:rgb, 152, 187, 187}}
  }

  def styles, do: @styles
end
