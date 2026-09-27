defmodule Beamcore.TUI.TerminalOptions do
  @moduledoc false

  # Mouse capture is opt-in in ex_ratatui (since 0.10.1) but on for us:
  # the chat screen scrolls with the wheel (Events handles scroll_up/down).
  # Override with: config :beamcore, :tui_terminal, mouse_capture: false
  @defaults [mouse_capture: true]

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
