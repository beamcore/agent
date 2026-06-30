defmodule Beamcore.TUI.Themes.Dracula do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 248, 248, 242}},
    muted: %Style{fg: {:rgb, 98, 114, 164}},
    subtle: %Style{fg: {:rgb, 68, 71, 90}},
    title: %Style{fg: {:rgb, 255, 121, 198}},
    panel: %Style{fg: {:rgb, 248, 248, 242}},
    border: %Style{fg: {:rgb, 98, 114, 164}},
    border_hot: %Style{fg: {:rgb, 139, 233, 253}},
    user: %Style{fg: {:rgb, 80, 250, 123}},
    assistant: %Style{fg: {:rgb, 248, 248, 242}},
    system: %Style{fg: {:rgb, 98, 114, 164}},
    accent: %Style{fg: {:rgb, 139, 233, 253}},
    running: %Style{fg: {:rgb, 241, 250, 140}},
    queued: %Style{fg: {:rgb, 189, 147, 249}},
    done: %Style{fg: {:rgb, 80, 250, 123}},
    memory: %Style{fg: {:rgb, 139, 233, 253}},
    error: %Style{fg: {:rgb, 255, 85, 85}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 248, 248, 242}},
    cursor: %Style{fg: {:rgb, 40, 42, 54}, bg: {:rgb, 139, 233, 253}},
    thinking: %Style{fg: {:rgb, 98, 114, 164}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 98, 114, 164}},
    status_hot: %Style{fg: {:rgb, 139, 233, 253}},
    syntax_keyword: %Style{fg: {:rgb, 255, 121, 198}},
    syntax_comment: %Style{fg: {:rgb, 98, 114, 164}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 241, 250, 140}},
    syntax_atom: %Style{fg: {:rgb, 189, 147, 249}},
    syntax_number: %Style{fg: {:rgb, 255, 184, 108}},
    syntax_module: %Style{fg: {:rgb, 139, 233, 253}},
    syntax_operator: %Style{fg: {:rgb, 255, 121, 198}},
    syntax_default: %Style{fg: {:rgb, 248, 248, 242}},
    code_block: %Style{fg: {:rgb, 248, 248, 242}, bg: {:rgb, 40, 42, 54}},
    code_header: %Style{fg: {:rgb, 98, 114, 164}, bg: {:rgb, 40, 42, 54}}
  }

  def styles, do: @styles
end
