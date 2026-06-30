defmodule Beamcore.TUI.Themes.RosePine do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 224, 222, 244}},
    muted: %Style{fg: {:rgb, 110, 106, 134}},
    subtle: %Style{fg: {:rgb, 65, 62, 82}},
    title: %Style{fg: {:rgb, 235, 188, 186}},
    panel: %Style{fg: {:rgb, 224, 222, 244}},
    border: %Style{fg: {:rgb, 110, 106, 134}},
    border_hot: %Style{fg: {:rgb, 235, 188, 186}},
    user: %Style{fg: {:rgb, 49, 207, 139}},
    assistant: %Style{fg: {:rgb, 224, 222, 244}},
    system: %Style{fg: {:rgb, 110, 106, 134}},
    accent: %Style{fg: {:rgb, 235, 188, 186}},
    running: %Style{fg: {:rgb, 246, 193, 119}},
    queued: %Style{fg: {:rgb, 196, 167, 231}},
    done: %Style{fg: {:rgb, 49, 207, 139}},
    memory: %Style{fg: {:rgb, 156, 207, 216}},
    error: %Style{fg: {:rgb, 235, 111, 146}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 224, 222, 244}},
    cursor: %Style{fg: {:rgb, 25, 23, 36}, bg: {:rgb, 235, 188, 186}},
    thinking: %Style{fg: {:rgb, 110, 106, 134}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 110, 106, 134}},
    status_hot: %Style{fg: {:rgb, 235, 188, 186}},
    syntax_keyword: %Style{fg: {:rgb, 196, 167, 231}},
    syntax_comment: %Style{fg: {:rgb, 110, 106, 134}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 49, 207, 139}},
    syntax_atom: %Style{fg: {:rgb, 246, 193, 119}},
    syntax_number: %Style{fg: {:rgb, 246, 193, 119}},
    syntax_module: %Style{fg: {:rgb, 235, 188, 186}},
    syntax_operator: %Style{fg: {:rgb, 196, 167, 231}},
    syntax_default: %Style{fg: {:rgb, 224, 222, 244}},
    code_block: %Style{fg: {:rgb, 224, 222, 244}, bg: {:rgb, 25, 23, 36}},
    code_header: %Style{fg: {:rgb, 110, 106, 134}, bg: {:rgb, 25, 23, 36}}
  }

  def styles, do: @styles
end
