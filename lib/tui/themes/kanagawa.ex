defmodule Beamcore.TUI.Themes.Kanagawa do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{fg: {:rgb, 220, 215, 186}},
    muted: %Style{fg: {:rgb, 112, 110, 100}},
    subtle: %Style{fg: {:rgb, 68, 66, 60}},
    title: %Style{fg: {:rgb, 126, 167, 196}},
    panel: %Style{fg: {:rgb, 220, 215, 186}},
    border: %Style{fg: {:rgb, 112, 110, 100}},
    border_hot: %Style{fg: {:rgb, 126, 167, 196}},
    user: %Style{fg: {:rgb, 152, 187, 108}},
    assistant: %Style{fg: {:rgb, 220, 215, 186}},
    system: %Style{fg: {:rgb, 112, 110, 100}},
    accent: %Style{fg: {:rgb, 126, 167, 196}},
    running: %Style{fg: {:rgb, 228, 180, 99}},
    queued: %Style{fg: {:rgb, 185, 144, 196}},
    done: %Style{fg: {:rgb, 152, 187, 108}},
    checkpoint: %Style{fg: {:rgb, 126, 167, 196}},
    error: %Style{fg: {:rgb, 195, 64, 67}, modifiers: [:bold]},
    input: %Style{fg: {:rgb, 220, 215, 186}},
    cursor: %Style{fg: {:rgb, 28, 27, 25}, bg: {:rgb, 126, 167, 196}},
    thinking: %Style{fg: {:rgb, 112, 110, 100}, modifiers: [:dim]},
    status: %Style{fg: {:rgb, 112, 110, 100}},
    status_hot: %Style{fg: {:rgb, 126, 167, 196}},
    syntax_keyword: %Style{fg: {:rgb, 185, 144, 196}},
    syntax_comment: %Style{fg: {:rgb, 112, 110, 100}, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 152, 187, 108}},
    syntax_atom: %Style{fg: {:rgb, 228, 180, 99}},
    syntax_number: %Style{fg: {:rgb, 228, 180, 99}},
    syntax_module: %Style{fg: {:rgb, 126, 167, 196}},
    syntax_operator: %Style{fg: {:rgb, 185, 144, 196}},
    syntax_default: %Style{fg: {:rgb, 220, 215, 186}}
  }

  def styles, do: @styles
end
