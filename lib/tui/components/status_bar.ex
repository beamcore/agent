defmodule Beamcore.TUI.Components.StatusBar do
  @moduledoc false

  alias Beamcore.TUI.Components.Mascot
  alias Beamcore.TUI.{NumberFormat, State, Theme}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  def widget(%{screen_type: :system}, width) when is_integer(width) do
    mascot = Mascot.frame(:idle, 0, true)
    switcher_text = "F1 Agent  F2 Chat  F3 System"
    right_text = "System overview"
    left_len = String.length(mascot) + 3 + String.length(switcher_text) + 3
    right_len = String.length(right_text)
    max_right_len = max(0, width - left_len - 2)

    right_text =
      if right_len > max_right_len,
        do: String.slice(right_text, 0, max(0, max_right_len - 3)) <> "...",
        else: right_text

    right_len = String.length(right_text)
    padding_len = max(0, width - left_len - right_len - 2)
    padding = String.duplicate(" ", padding_len)

    spans = [
      %Span{content: mascot, style: Theme.style(:status_hot)},
      %Span{content: " · ", style: Theme.style(:status)},
      %Span{content: "F1 Agent", style: Theme.style(:status)},
      %Span{content: "  ", style: Theme.style(:status)},
      %Span{content: "F2 Chat", style: Theme.style(:status)},
      %Span{content: "  ", style: Theme.style(:status)},
      %Span{content: "F3 System", style: Theme.style(:status_hot)},
      %Span{content: " · ", style: Theme.style(:status)},
      %Span{content: padding, style: Theme.style(:status)},
      %Span{content: right_text, style: Theme.style(:status)}
    ]

    %Paragraph{text: [%Line{spans: spans}], style: Theme.style(:status)}
  end

  def widget(state, width) when is_integer(width) do
    usage = State.usage(state.session)
    mascot = Mascot.frame(state.status, state.spinner_step, state.unicode?)
    provider = state.provider || "provider"
    model = state.model || State.model(state.session)
    provider_model = "#{provider}/#{model}"

    tokens = format_token_stats(usage)

    right_text =
      case State.ctrl_c_hint(state.ctrl_c_pending) do
        nil -> State.wait_status_text(state) || "#{tokens}  #{provider_model}"
        hint -> hint
      end

    switcher_text = "F1 Agent  F2 Chat  F3 System"
    left_len = String.length(mascot) + 3 + String.length(switcher_text) + 3
    right_len = visible_width(right_text)

    max_right_len = max(0, width - left_len - 2)

    right_text =
      if right_len > max_right_len do
        truncate_to_width(right_text, max(0, max_right_len - 3)) <> "..."
      else
        right_text
      end

    right_len = visible_width(right_text)
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
      %Span{content: "  ", style: Theme.style(:status)},
      %Span{
        content: "F3 System",
        style:
          if(active == :system,
            do: Theme.style(:status_hot),
            else: Theme.style(:status)
          )
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

  # Always show all symbols. Stable layout — no jumps.
  defp format_token_stats(usage) do
    [
      "↑#{NumberFormat.compact(usage.prompt_tokens)}",
      "↓#{NumberFormat.compact(usage.completion_tokens)}",
      "R#{NumberFormat.compact(usage.cached_tokens)}",
      "#{NumberFormat.compact(usage.total_tokens)}t"
    ]
    |> Enum.join(" ")
  end

  defp visible_width(text) do
    text
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.length()
  end

  defp truncate_to_width(text, max_width) do
    clean = String.replace(text, ~r/\e\[[0-9;]*m/, "")

    if String.length(clean) <= max_width do
      text
    else
      String.slice(text, 0, max_width)
    end
  end
end
