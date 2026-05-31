defmodule Beamcore.TUI.Components.StatusBar do
  @moduledoc false

  alias Beamcore.TUI.Components.Mascot
  alias Beamcore.TUI.{State, Theme, Wrap}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Number.SI

  def widget(state, mode) do
    usage = State.usage(state.session)
    mascot = Mascot.frame(state.status, state.spinner_step, state.unicode?)
    model = State.model(state.session)

    tokens =
      "#{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}"

    text =
      case mode do
        :narrow ->
          "#{mascot} · #{model} · #{tokens} tok"

        _ ->
          left = "#{mascot} · "
          right = "#{model} · #{tokens} tok"

          # Pad left to align right side
          padding = String.duplicate(" ", max(0, 40 - String.length(left)))
          "#{left}#{padding}#{right}"
      end
      |> Wrap.truncate_line(220)

    %Paragraph{text: styled_text(text, String.length(mascot)), style: Theme.style(:status)}
  end

  defp styled_text(text, mascot_length) do
    if String.length(text) <= mascot_length do
      [%Line{spans: [%Span{content: text, style: Theme.style(:status_hot)}]}]
    else
      mascot_part = String.slice(text, 0, mascot_length)
      rest_part = String.slice(text, mascot_length, String.length(text) - mascot_length)

      [
        %Line{
          spans: [
            %Span{content: mascot_part, style: Theme.style(:status_hot)},
            %Span{content: rest_part}
          ]
        }
      ]
    end
  end

end
