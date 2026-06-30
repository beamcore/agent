defmodule Beamcore.TUI.Components.StatusBar do
  @moduledoc false

  alias Beamcore.TUI.Components.Mascot
  alias Beamcore.TUI.{State, Theme}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias Number.SI

  # Always-visible quit/help hints. Mode switching now lives in the top mode
  # bar, so the status line no longer carries the F1/F2/F3 switcher.
  @hints "^C quit · ? help"

  def widget(%{screen_type: :system}, width) when is_integer(width) do
    line(Mascot.frame(:idle, 0, true), "System overview", width)
  end

  def widget(state, width) when is_integer(width) do
    mascot = Mascot.frame(state.status, state.spinner_step, state.unicode?)
    line(mascot, info_text(state), width)
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

  defp info_text(state) do
    case State.ctrl_c_hint(state.ctrl_c_pending) do
      nil -> State.wait_status_text(state) || provider_text(state)
      hint -> hint
    end
  end

  defp provider_text(state) do
    usage = State.usage(state.session)
    provider = state.provider || "provider"
    model = state.model || State.model(state.session)

    tokens =
      "#{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}"

    "#{provider}/#{model} · tok #{tokens}"
  end

  defp line(mascot, info, width) do
    fixed = String.length(mascot) + 3 + String.length(@hints) + 2
    info = truncate(info, max(0, width - fixed))

    pad =
      max(0, width - String.length(mascot) - 3 - String.length(info) - String.length(@hints) - 2)

    spans = [
      %Span{content: mascot, style: Theme.style(:status_hot)},
      %Span{content: " · ", style: Theme.style(:status)},
      %Span{content: info, style: Theme.style(:status)},
      %Span{content: String.duplicate(" ", pad), style: Theme.style(:status)},
      %Span{content: @hints, style: Theme.style(:status)}
    ]

    %Paragraph{text: [%Line{spans: spans}], style: Theme.style(:status)}
  end

  defp truncate(_text, limit) when limit <= 0, do: ""

  defp truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, max(0, limit - 3)) <> "..."
    end
  end
end
