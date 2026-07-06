defmodule Beamcore.TUI.Themes.Default do
  @moduledoc false
  alias ExRatatui.Style

  @styles %{
    base: %Style{},
    muted: %Style{fg: :gray},
    subtle: %Style{fg: :dark_gray},
    title: %Style{},
    panel: %Style{},
    border: %Style{fg: :dark_gray},
    border_hot: %Style{fg: :cyan},
    user: %Style{fg: :green},
    assistant: %Style{},
    system: %Style{fg: :gray},
    accent: %Style{fg: :cyan},
    running: %Style{fg: :yellow},
    queued: %Style{fg: :blue},
    done: %Style{fg: :green},
    memory: %Style{fg: :cyan},
    error: %Style{fg: :red, modifiers: [:bold]},
    input: %Style{},
    cursor: %Style{fg: :black, bg: :cyan},
    thinking: %Style{fg: :gray, modifiers: [:dim]},
    status: %Style{fg: :gray},
    status_hot: %Style{fg: :cyan},
    syntax_keyword: %Style{fg: :cyan},
    syntax_comment: %Style{fg: :gray, modifiers: [:dim]},
    syntax_string: %Style{fg: :green},
    syntax_atom: %Style{fg: :cyan},
    syntax_number: %Style{fg: :yellow},
    syntax_module: %Style{fg: :yellow},
    syntax_operator: %Style{fg: :gray},
    syntax_default: %Style{},
    code_block: %Style{fg: :white, bg: :black},
    code_header: %Style{fg: :gray, bg: :black}
  }

  def styles, do: @styles
end
