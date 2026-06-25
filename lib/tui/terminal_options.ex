defmodule Beamcore.TUI.TerminalOptions do
  @moduledoc false

  @defaults [
    poll_interval: 1,
    mouse_capture: false,
    focus_events: false
  ]

  @terminal_keys Keyword.keys(@defaults)

  def apply(opts) when is_list(opts) do
    configured =
      :beamcore
      |> Application.get_env(:tui_terminal, [])
      |> Keyword.take(@terminal_keys)

    @defaults
    |> Keyword.merge(configured)
    |> Keyword.merge(opts)
  end

  def defaults, do: @defaults
end
