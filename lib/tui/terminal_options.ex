defmodule Beamcore.TUI.TerminalOptions do
  @moduledoc false

  @defaults []

  @terminal_keys [:poll_interval, :mouse_capture, :focus_events]

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
