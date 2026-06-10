defmodule Beamcore.TUI.Theme do
  @moduledoc """
  Dark-first visual system for the agent TUI.
  """

  alias ExRatatui.Style

  @midnight {:rgb, 5, 10, 24}
  @panel {:rgb, 9, 21, 44}
  @muted {:rgb, 112, 139, 171}
  @subtle {:rgb, 80, 100, 130}
  @ice {:rgb, 218, 240, 255}
  @blue {:rgb, 46, 144, 255}
  @cyan {:rgb, 70, 215, 255}
  @success {:rgb, 92, 220, 187}
  @amber {:rgb, 245, 180, 72}
  @red {:rgb, 255, 104, 112}

  @styles %{
    base: %Style{fg: @ice, bg: @midnight},
    panel_bg: %Style{fg: @ice, bg: @panel},
    title: %Style{fg: @ice, modifiers: [:bold]},
    subtitle: %Style{fg: @muted},
    muted: %Style{fg: @muted},
    subtle: %Style{fg: @subtle},
    border: %Style{fg: @subtle},
    border_hot: %Style{fg: @blue, modifiers: [:bold]},
    user: %Style{fg: @success, modifiers: [:bold]},
    assistant: %Style{fg: @ice},
    system: %Style{fg: @muted},
    panel: %Style{fg: @ice},
    accent: %Style{fg: @cyan, modifiers: [:bold]},
    running: %Style{fg: @amber, modifiers: [:bold]},
    queued: %Style{fg: @blue},
    done: %Style{fg: @success},
    checkpoint: %Style{fg: @cyan, modifiers: [:bold]},
    checkpoint_active: %Style{fg: @amber, modifiers: [:bold]},
    blocked: %Style{fg: @amber, modifiers: [:bold]},
    error: %Style{fg: @red, modifiers: [:bold]},
    input: %Style{fg: @ice},
    cursor: %Style{fg: @midnight, bg: @cyan},
    status: %Style{fg: @muted},
    status_hot: %Style{fg: @cyan, modifiers: [:bold]},
    yolo: %Style{fg: @red, modifiers: [:bold]}
  }

  def style(name), do: Map.fetch!(@styles, name)

  def border(:thinking), do: style(:border_hot)
  def border(:local_search), do: style(:border_hot)
  def border(:tool_running), do: style(:running)
  def border(:error), do: style(:error)
  def border(_status), do: style(:border)
end
