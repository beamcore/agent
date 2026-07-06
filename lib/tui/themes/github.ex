defmodule Beamcore.TUI.Themes.GitHub do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 36, 41, 47}},
    muted: %Style{fg: {:rgb, 139, 148, 158}},
    subtle: %Style{fg: {:rgb, 200, 205, 212}},
    title: %Style{fg: {:rgb, 9, 105, 218}},
    panel: %Style{fg: {:rgb, 36, 41, 47}},
    border: %Style{fg: {:rgb, 200, 205, 212}},
    border_hot: %Style{fg: {:rgb, 9, 105, 218}},
    user: %Style{fg: {:rgb, 9, 105, 218}},
    assistant: %Style{fg: {:rgb, 36, 41, 47}},
    system: %Style{fg: {:rgb, 139, 148, 158}},
    accent: %Style{fg: {:rgb, 9, 105, 218}},
    running: %Style{fg: {:rgb, 210, 153, 34}},
    queued: %Style{fg: {:rgb, 137, 87, 229}},
    done: %Style{fg: {:rgb, 26, 127, 55}},
    memory: %Style{fg: {:rgb, 9, 105, 218}},
    error: %Style{fg: {:rgb, 209, 36, 47}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 36, 41, 47}},
    cursor: %Style{fg: {:rgb, 255, 255, 255}, bg: {:rgb, 9, 105, 218}},
    thinking: %Style{fg: {:rgb, 139, 148, 158}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 139, 148, 158}},
    status_hot: %Style{fg: {:rgb, 9, 105, 218}},
    syntax_keyword: %Style{fg: {:rgb, 209, 36, 47}},
    syntax_comment: %Style{fg: {:rgb, 139, 148, 158}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 3, 77, 32}},
    syntax_atom: %Style{fg: {:rgb, 137, 87, 229}},
    syntax_number: %Style{fg: {:rgb, 9, 105, 218}},
    syntax_module: %Style{fg: {:rgb, 210, 153, 34}},
    syntax_operator: %Style{fg: {:rgb, 209, 36, 47}},
    syntax_default: %Style{fg: {:rgb, 36, 41, 47}},
    code_block: %Style{fg: {:rgb, 36, 41, 47}, bg: {:rgb, 255, 255, 255}},
    code_header: %Style{fg: {:rgb, 139, 148, 158}, bg: {:rgb, 255, 255, 255}}
  }

  def styles, do: @styles
end
