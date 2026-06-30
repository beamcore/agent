defmodule Beamcore.TUI.Themes.Catppuccin do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 205, 214, 244}},
    muted: %Style{fg: {:rgb, 108, 112, 134}},
    subtle: %Style{fg: {:rgb, 69, 71, 90}},
    title: %Style{fg: {:rgb, 137, 180, 250}},
    panel: %Style{fg: {:rgb, 205, 214, 244}},
    border: %Style{fg: {:rgb, 108, 112, 134}},
    border_hot: %Style{fg: {:rgb, 137, 180, 250}},
    user: %Style{fg: {:rgb, 166, 227, 161}},
    assistant: %Style{fg: {:rgb, 205, 214, 244}},
    system: %Style{fg: {:rgb, 108, 112, 134}},
    accent: %Style{fg: {:rgb, 137, 180, 250}},
    running: %Style{fg: {:rgb, 249, 226, 175}},
    queued: %Style{fg: {:rgb, 203, 166, 247}},
    done: %Style{fg: {:rgb, 166, 227, 161}},
    memory: %Style{fg: {:rgb, 137, 180, 250}},
    error: %Style{fg: {:rgb, 243, 139, 168}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 205, 214, 244}},
    cursor: %Style{fg: {:rgb, 30, 30, 46}, bg: {:rgb, 137, 180, 250}},
    thinking: %Style{fg: {:rgb, 108, 112, 134}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 108, 112, 134}},
    status_hot: %Style{fg: {:rgb, 137, 180, 250}},
    syntax_keyword: %Style{fg: {:rgb, 137, 180, 250}},
    syntax_comment: %Style{fg: {:rgb, 108, 112, 134}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 166, 227, 161}},
    syntax_atom: %Style{fg: {:rgb, 203, 166, 247}},
    syntax_number: %Style{fg: {:rgb, 249, 226, 175}},
    syntax_module: %Style{fg: {:rgb, 137, 180, 250}},
    syntax_operator: %Style{fg: {:rgb, 137, 180, 250}},
    syntax_default: %Style{fg: {:rgb, 205, 214, 244}},
    code_block: %Style{fg: {:rgb, 205, 214, 244}, bg: {:rgb, 30, 30, 46}},
    code_header: %Style{fg: {:rgb, 108, 112, 134}, bg: {:rgb, 30, 30, 46}}
  }

  def styles, do: @styles
end
