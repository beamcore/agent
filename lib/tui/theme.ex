defmodule Beamcore.TUI.Theme do
  @moduledoc false

  alias ExRatatui.Style

  @styles %{
    base: %Style{},
    muted: %Style{fg: :dark_gray},
    subtle: %Style{fg: :gray},
    title: %Style{modifiers: [:bold]},
    panel: %Style{},
    border: %Style{fg: :gray},
    border_hot: %Style{fg: :cyan, modifiers: [:bold]},
    user: %Style{fg: :green, modifiers: [:bold]},
    assistant: %Style{},
    system: %Style{fg: :dark_gray},
    accent: %Style{fg: :cyan, modifiers: [:bold]},
    running: %Style{fg: :yellow, modifiers: [:bold]},
    queued: %Style{fg: :blue},
    done: %Style{fg: :green},
    checkpoint: %Style{fg: :cyan},
    error: %Style{fg: :red, modifiers: [:bold]},
    input: %Style{},
    cursor: %Style{fg: :black, bg: :cyan},
    thinking: %Style{fg: :dark_gray, modifiers: [:dim]},
    status: %Style{fg: :dark_gray},
    status_hot: %Style{fg: :cyan, modifiers: [:bold]}
  }

  def style(name), do: Map.get(@styles, name, %Style{})

  def border(:error), do: style(:error)
  def border(_status), do: style(:border)
end
