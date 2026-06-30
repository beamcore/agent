defmodule Beamcore.TUI.Themes.Nightfox do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 192, 199, 213}},
    muted: %Style{fg: {:rgb, 101, 110, 131}},
    subtle: %Style{fg: {:rgb, 59, 66, 82}},
    title: %Style{fg: {:rgb, 113, 189, 222}},
    panel: %Style{fg: {:rgb, 192, 199, 213}},
    border: %Style{fg: {:rgb, 101, 110, 131}},
    border_hot: %Style{fg: {:rgb, 113, 189, 222}},
    user: %Style{fg: {:rgb, 127, 200, 132}},
    assistant: %Style{fg: {:rgb, 192, 199, 213}},
    system: %Style{fg: {:rgb, 101, 110, 131}},
    accent: %Style{fg: {:rgb, 113, 189, 222}},
    running: %Style{fg: {:rgb, 230, 180, 99}},
    queued: %Style{fg: {:rgb, 180, 142, 214}},
    done: %Style{fg: {:rgb, 127, 200, 132}},
    memory: %Style{fg: {:rgb, 113, 189, 222}},
    error: %Style{fg: {:rgb, 214, 95, 108}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 192, 199, 213}},
    cursor: %Style{fg: {:rgb, 36, 39, 48}, bg: {:rgb, 113, 189, 222}},
    thinking: %Style{fg: {:rgb, 101, 110, 131}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 101, 110, 131}},
    status_hot: %Style{fg: {:rgb, 113, 189, 222}},
    syntax_keyword: %Style{fg: {:rgb, 180, 142, 214}},
    syntax_comment: %Style{fg: {:rgb, 101, 110, 131}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 127, 200, 132}},
    syntax_atom: %Style{fg: {:rgb, 230, 180, 99}},
    syntax_number: %Style{fg: {:rgb, 230, 180, 99}},
    syntax_module: %Style{fg: {:rgb, 113, 189, 222}},
    syntax_operator: %Style{fg: {:rgb, 180, 142, 214}},
    syntax_default: %Style{fg: {:rgb, 192, 199, 213}},
    code_block: %Style{fg: {:rgb, 192, 199, 213}, bg: {:rgb, 36, 39, 48}},
    code_header: %Style{fg: {:rgb, 101, 110, 131}, bg: {:rgb, 36, 39, 48}}
  }

  def styles, do: @styles
end
