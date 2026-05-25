defmodule Beamcore.Agent.TUI.Components.StatusBar do
  @moduledoc false

  alias Beamcore.Agent.TUI.Components.{Activity, Mascot}
  alias Beamcore.Agent.TUI.{State, Theme, Wrap}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Number.SI

  def widget(state, mode) do
    usage = State.usage(state.session)
    session_id = if state.session, do: state.session.session_id, else: "starting"
    yolo = if State.yolo?(state.session), do: " · YOLO", else: ""
    mascot = Mascot.frame(state.status, state.spinner_step, state.unicode?)
    model = State.model(state.session)
    provider = State.provider()
    yolo? = State.yolo?(state.session)

    text =
      case mode do
        :narrow ->
          "#{mascot} #{status(state.status)}#{yolo}  #{State.policy_status()}  #{session_id}  tok #{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}"

        _ ->
          [
            "#{mascot} #{status(state.status)}#{yolo}",
            State.policy_status(),
            model,
            provider,
            "session #{session_id}",
            "tok #{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}",
            Activity.compact_text(state)
          ]
          |> Enum.join("  •  ")
      end
      |> Wrap.truncate_line(220)

    if yolo? do
      mascot_length = String.length(mascot)

      %Paragraph{
        text: styled_text(text, mascot_length),
        style: Theme.style(:status)
      }
    else
      %Paragraph{text: text, style: Theme.style(:status)}
    end
  end

  defp styled_text(text, mascot_length) do
    if String.length(text) <= mascot_length do
      [%Line{spans: [%Span{content: text, style: Theme.style(:yolo)}]}]
    else
      mascot_part = String.slice(text, 0, mascot_length)
      rest_part = String.slice(text, mascot_length, String.length(text) - mascot_length)

      [
        %Line{
          spans: [
            %Span{content: mascot_part, style: Theme.style(:yolo)},
            %Span{content: rest_part}
          ]
        }
      ]
    end
  end

  defp status(:idle), do: "idle"
  defp status(:thinking), do: "thinking"
  defp status(:tool_running), do: "tool running"
  defp status(:waiting_for_confirmation), do: "waiting confirmation"
  defp status(:error), do: "error"
  defp status(other), do: to_string(other)
end
