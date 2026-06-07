defmodule Beamcore.TUI.Components.StatusBar do
  @moduledoc false

  alias Beamcore.TUI.Components.Mascot
  alias Beamcore.TUI.{State, Theme}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Number.SI

  def widget(state, width) when is_integer(width) do
    usage = State.usage(state.session)
    mascot = Mascot.frame(state.status, state.spinner_step, state.unicode?)
    provider = Beamcore.Config.active_provider()
    model = State.model(state.session)
    provider_model = "#{provider}/#{model}"

    tokens =
      "#{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}"

    right_text =
      case state.notice do
        notice when is_binary(notice) and notice != "" ->
          notice

        _ ->
          "#{provider_model} · #{tokens} tok"
      end

    # Calculate padding
    # mascot length + " · F1: Dev · F2: Chat · " is mascot_len + 23
    mascot_len = String.length(mascot)
    left_len = mascot_len + 23
    right_len = String.length(right_text)

    # Ensure right_text fits in the remaining space
    max_right_len = max(0, width - left_len - 2)
    right_text =
      if right_len > max_right_len do
        String.slice(right_text, 0, max(0, max_right_len - 3)) <> "..."
      else
        right_text
      end

    right_len = String.length(right_text)
    padding_len = max(0, width - left_len - right_len - 2)
    padding = String.duplicate(" ", padding_len)

    spans = [
      %Span{content: mascot, style: Theme.style(:status_hot)},
      %Span{content: " · ", style: Theme.style(:status)},
      %Span{content: "F1: Dev", style: if(state.screen_type == :agent, do: Theme.style(:status_hot), else: Theme.style(:status))},
      %Span{content: " · ", style: Theme.style(:status)},
      %Span{content: "F2: Chat", style: if(state.screen_type == :chat, do: Theme.style(:status_hot), else: Theme.style(:status))},
      %Span{content: " · ", style: Theme.style(:status)},
      %Span{content: padding, style: Theme.style(:status)},
      %Span{content: right_text, style: Theme.style(:status)}
    ]

    %Paragraph{
      text: [%Line{spans: spans}],
      style: Theme.style(:status)
    }
  end

  def widget(state, mode) when is_atom(mode) do
    width =
      case mode do
        :narrow -> 80
        :medium -> 100
        _ -> 120
      end

    widget(state, width)
  end
end
