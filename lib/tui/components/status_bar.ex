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
    provider = State.provider(state.session)
    model = State.model(state.session)
    provider_model = "#{provider}/#{model}"

    tokens =
      "#{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}"

    right_text =
      case State.ctrl_c_hint(state.ctrl_c_pending) do
        nil -> State.wait_status_text(state) || "#{provider_model} · tok #{tokens}"
        hint -> hint
      end

    switcher_text = "F1 Agent  F2 Chat"
    left_len = String.length(mascot) + 3 + String.length(switcher_text) + 3
    right_len = String.length(right_text)

    # Ensure right_text fits in the remaining space.
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
    active = state.screen_type

    spans = [
      %Span{content: mascot, style: Theme.style(:status_hot)},
      %Span{content: " · ", style: Theme.style(:status)},
      %Span{
        content: "F1 Agent",
        style: if(active == :agent, do: Theme.style(:status_hot), else: Theme.style(:status))
      },
      %Span{content: "  ", style: Theme.style(:status)},
      %Span{
        content: "F2 Chat",
        style: if(active == :chat, do: Theme.style(:status_hot), else: Theme.style(:status))
      },
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
