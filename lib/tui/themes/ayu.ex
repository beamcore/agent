defmodule Beamcore.TUI.Themes.Ayu do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 182, 188, 197}},
    muted: %Style{fg: {:rgb, 92, 103, 115}},
    subtle: %Style{fg: {:rgb, 56, 65, 76}},
    title: %Style{fg: {:rgb, 87, 181, 232}},
    panel: %Style{fg: {:rgb, 182, 188, 197}},
    border: %Style{fg: {:rgb, 92, 103, 115}},
    border_hot: %Style{fg: {:rgb, 87, 181, 232}},
    user: %Style{fg: {:rgb, 73, 200, 149}},
    assistant: %Style{fg: {:rgb, 182, 188, 197}},
    system: %Style{fg: {:rgb, 92, 103, 115}},
    accent: %Style{fg: {:rgb, 87, 181, 232}},
    running: %Style{fg: {:rgb, 255, 196, 59}},
    queued: %Style{fg: {:rgb, 193, 132, 231}},
    done: %Style{fg: {:rgb, 73, 200, 149}},
    checkpoint: %Style{fg: {:rgb, 87, 181, 232}},
    error: %Style{fg: {:rgb, 255, 92, 87}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 182, 188, 197}},
    cursor: %Style{fg: {:rgb, 31, 36, 46}, bg: {:rgb, 87, 181, 232}},
    thinking: %Style{fg: {:rgb, 92, 103, 115}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 92, 103, 115}},
    status_hot: %Style{fg: {:rgb, 87, 181, 232}},
    syntax_keyword: %Style{fg: {:rgb, 255, 92, 87}},
    syntax_comment: %Style{fg: {:rgb, 92, 103, 115}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 73, 200, 149}},
    syntax_atom: %Style{fg: {:rgb, 255, 196, 59}},
    syntax_number: %Style{fg: {:rgb, 255, 196, 59}},
    syntax_module: %Style{fg: {:rgb, 87, 181, 232}},
    syntax_operator: %Style{fg: {:rgb, 255, 92, 87}},
    syntax_default: %Style{fg: {:rgb, 182, 188, 197}},
    code_block: %Style{fg: {:rgb, 182, 188, 197}, bg: {:rgb, 31, 36, 46}},
    code_header: %Style{fg: {:rgb, 92, 103, 115}, bg: {:rgb, 31, 36, 46}}
  }

  def styles, do: @styles
end
