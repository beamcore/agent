defmodule Beamcore.TUI.Shell do
  @moduledoc """
  The shell chrome shared by every mode.

  Renders the mode bar on the top row, then delegates the remaining area to the
  active mode's body — the chat, the dashboard, or a coming-soon placeholder —
  shifted down to sit beneath the bar.
  """

  alias Beamcore.TUI.Components.{ComingSoon, Help, ModeBar, Splash, StatusBar}
  alias Beamcore.TUI.{Mode, MultiScreenState, Render}
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect

  @top_height 1

  @doc "Composes the full scene for the active mode."
  def render(%MultiScreenState{splash?: true} = multi, frame) do
    Splash.widgets(frame, multi.splash_step, splash_unicode?(multi))
  end

  def render(%MultiScreenState{} = multi, frame) do
    width = max(frame.width, 1)
    height = max(frame.height, 1)

    top = %Rect{x: 0, y: 0, width: width, height: @top_height}
    body_frame = %Frame{width: width, height: max(height - @top_height, 1)}
    body = multi |> body_widgets(body_frame) |> offset_y(@top_height)

    [{ModeBar.tabs(multi.active_mode), top} | body]
    |> maybe_help(multi, %Rect{x: 0, y: 0, width: width, height: height})
  end

  # Coming-soon and dashboard modes have no composer, so the shell owns their
  # help overlay. Chat renders its own help from the chat state.
  defp maybe_help(widgets, %MultiScreenState{show_help: true} = multi, area),
    do: widgets ++ [{Help.widget(multi.active_mode), area}]

  defp maybe_help(widgets, _multi, _area), do: widgets

  defp body_widgets(%MultiScreenState{active_mode: :chat} = multi, frame),
    do: Render.render(multi.chat_state, frame)

  defp body_widgets(%MultiScreenState{active_mode: :dashboard} = multi, frame),
    do: Render.render(multi.dashboard_state, frame)

  defp body_widgets(%MultiScreenState{active_mode: mode} = multi, frame) do
    area = %Rect{x: 0, y: 0, width: max(frame.width, 1), height: max(frame.height, 1)}
    body = %{area | height: max(area.height - 1, 1)}
    status = %{area | y: body.height, height: 1}

    [
      {ComingSoon.widget(Mode.fetch!(mode)), body},
      {StatusBar.widget(multi.chat_state, status.width), status}
    ]
  end

  defp offset_y(widgets, dy) do
    Enum.map(widgets, fn {widget, %Rect{} = rect} -> {widget, %{rect | y: rect.y + dy}} end)
  end

  defp splash_unicode?(%MultiScreenState{chat_state: %{unicode?: unicode?}}), do: unicode?
  defp splash_unicode?(_multi), do: true
end
