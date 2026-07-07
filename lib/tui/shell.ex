defmodule Beamcore.TUI.Shell do
  @moduledoc """
  The shell chrome shared by every mode.

  Delegates the top of the screen to the active mode's body — the chat, the
  dashboard, or a coming-soon placeholder — and owns a two-row footer beneath
  it: the mode bar (tab strip) above the status line.
  """

  alias Beamcore.TUI.Components.{ComingSoon, Help, ModeBar, Splash, StatusBar}
  alias Beamcore.TUI.{Mode, MultiScreenState, Render}
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect

  @footer_height 2

  @doc "Composes the full scene for the active mode."
  def render(%MultiScreenState{splash?: true} = multi, frame) do
    Splash.widgets(frame, multi.splash_step, unicode?(multi))
  end

  def render(%MultiScreenState{} = multi, frame) do
    width = max(frame.width, 1)
    height = max(frame.height, 1)

    body_frame = %Frame{width: width, height: max(height - @footer_height, 1)}
    body = body_widgets(multi, body_frame)

    (body ++ footer_widgets(multi, width, height))
    |> maybe_help(multi, %Rect{x: 0, y: 0, width: width, height: height})
  end

  # Tab strip on the second-to-last row, status line on the last row.
  defp footer_widgets(multi, width, height) do
    tabs = %Rect{x: 0, y: max(height - 2, 0), width: width, height: 1}
    status = %Rect{x: 0, y: max(height - 1, 0), width: width, height: 1}

    [
      {ModeBar.tabs(multi.active_mode, unicode?(multi)), tabs},
      {StatusBar.widget(status_state(multi), width), status}
    ]
  end

  defp status_state(%MultiScreenState{active_mode: :dashboard} = multi), do: dashboard_view(multi)
  defp status_state(%MultiScreenState{} = multi), do: multi.chat_state

  # Coming-soon and dashboard modes have no composer, so the shell owns their
  # help overlay. Chat renders its own help from the chat state.
  defp maybe_help(widgets, %MultiScreenState{show_help: true} = multi, area),
    do: widgets ++ [{Help.widget(multi.active_mode, unicode?(multi)), area}]

  defp maybe_help(widgets, _multi, _area), do: widgets

  defp body_widgets(%MultiScreenState{active_mode: :chat} = multi, frame),
    do: Render.render(multi.chat_state, frame)

  defp body_widgets(%MultiScreenState{active_mode: :dashboard} = multi, frame),
    do: Render.render(dashboard_view(multi), frame)

  defp body_widgets(%MultiScreenState{active_mode: mode} = multi, frame) do
    area = %Rect{x: 0, y: 0, width: max(frame.width, 1), height: max(frame.height, 1)}
    [{ComingSoon.widget(Mode.fetch!(mode), unicode?(multi)), area}]
  end

  # The dashboard borrows the chat state's live activity trace, ctrl-c arm, and
  # unicode capability so its panels and status line reflect the running agent.
  defp dashboard_view(%MultiScreenState{} = multi) do
    %{
      multi.dashboard_state
      | activity: activity_of(multi.chat_state),
        ctrl_c_pending: Map.get(multi.chat_state, :ctrl_c_pending, false),
        unicode?: unicode?(multi)
    }
  end

  defp unicode?(%MultiScreenState{chat_state: %{unicode?: unicode?}}), do: unicode?
  defp unicode?(_multi), do: true

  defp activity_of(%{activity: activity}) when is_list(activity), do: activity
  defp activity_of(_chat_state), do: []
end
