defmodule Beamcore.Agent.TUI.Components.StatusBar do
  @moduledoc false

  alias Beamcore.Agent.TUI.Components.{Activity, Mascot}
  alias Beamcore.Agent.TUI.{State, Theme, Wrap}
  alias ExRatatui.Widgets.Paragraph
  alias Number.SI

  def widget(state, mode) do
    usage = State.usage(state.session)
    session_id = if state.session, do: state.session.session_id, else: "starting"
    yolo = if State.yolo?(state.session), do: " · YOLO", else: ""
    mascot = Mascot.frame(state.status, state.spinner_step, state.unicode?)
    model = State.model(state.session)
    provider = State.provider()

    text =
      case mode do
        :narrow ->
          "#{mascot} #{status(state.status)}#{yolo}  #{session_id}  tok #{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}"

        _ ->
          [
            "#{mascot} #{status(state.status)}#{yolo}",
            model,
            provider,
            "session #{session_id}",
            "tok #{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}",
            Activity.compact_text(state)
          ]
          |> Enum.join("  •  ")
      end
      |> Wrap.truncate_line(220)

    %Paragraph{text: text, style: style(state)}
  end

  defp style(state) do
    if State.yolo?(state.session), do: Theme.style(:yolo), else: Theme.style(:status)
  end

  defp status(:idle), do: "idle"
  defp status(:thinking), do: "thinking"
  defp status(:tool_running), do: "tool running"
  defp status(:waiting_for_confirmation), do: "waiting confirmation"
  defp status(:error), do: "error"
  defp status(other), do: to_string(other)
end
