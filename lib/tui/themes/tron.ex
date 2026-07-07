defmodule Beamcore.TUI.Themes.Tron do
  @moduledoc false
  alias ExRatatui.Style

  @grid_bg {:rgb, 1, 8, 16}
  @panel_bg {:rgb, 3, 18, 31}
  @deep_blue {:rgb, 5, 32, 54}
  @cyan {:rgb, 0, 229, 255}
  @ice {:rgb, 198, 246, 255}
  @blue {:rgb, 42, 151, 255}
  @dim_blue {:rgb, 28, 83, 114}
  @orange {:rgb, 255, 142, 35}
  @red {:rgb, 255, 76, 76}

  @styles %{
    base: %Style{fg: @ice},
    muted: %Style{fg: @dim_blue},
    subtle: %Style{fg: @deep_blue},
    title: %Style{fg: @cyan, modifiers: [:bold]},
    panel: %Style{fg: @ice, bg: @panel_bg},
    border: %Style{fg: @blue},
    border_hot: %Style{fg: @cyan, modifiers: [:bold]},
    user: %Style{fg: @orange},
    assistant: %Style{fg: @ice},
    system: %Style{fg: @dim_blue},
    accent: %Style{fg: @cyan, modifiers: [:bold]},
    running: %Style{fg: @orange},
    queued: %Style{fg: @blue},
    done: %Style{fg: {:rgb, 80, 255, 190}},
    memory: %Style{fg: @blue},
    error: %Style{fg: @red, modifiers: [:bold]},
    input: %Style{fg: @ice, bg: @grid_bg},
    cursor: %Style{fg: @grid_bg, bg: @cyan},
    thinking: %Style{fg: @dim_blue, modifiers: [:dim]},
    status: %Style{fg: @dim_blue, bg: @grid_bg},
    status_hot: %Style{fg: @orange, bg: @grid_bg, modifiers: [:bold]},
    syntax_keyword: %Style{fg: @cyan, modifiers: [:bold]},
    syntax_comment: %Style{fg: @dim_blue, modifiers: [:dim]},
    syntax_string: %Style{fg: {:rgb, 80, 255, 190}},
    syntax_atom: %Style{fg: @orange},
    syntax_number: %Style{fg: @blue},
    syntax_module: %Style{fg: {:rgb, 145, 224, 255}},
    syntax_operator: %Style{fg: @cyan},
    syntax_default: %Style{fg: @ice},
    code_block: %Style{fg: @ice, bg: @grid_bg},
    code_header: %Style{fg: @cyan, bg: @grid_bg, modifiers: [:bold]}
  }

  def styles, do: @styles
end
