defmodule Beamcore.TUI.Components.StatusBar do
  @moduledoc false

  alias Beamcore.TUI.Components.Mascot
  alias Beamcore.TUI.{NumberFormat, State, Theme}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  # Always-visible quit/help hints, rendered as accent "pills". Mode switching
  # lives in the tab strip, so the status line no longer carries the switcher.
  @key_hints [{"^C", "quit"}, {"?", "help"}]

  def widget(%{screen_type: :system} = state, width) when is_integer(width) do
    info = State.ctrl_c_hint(Map.get(state, :ctrl_c_pending)) || system_hint(state)
    line(Mascot.frame(:idle, 0, Map.get(state, :unicode?, true)), info, width)
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

  defp system_hint(%{active_panel: :activity}), do: "Activity · Tab panel · ↑↓ PgUp/Dn scroll"
  defp system_hint(_state), do: "Providers · Tab panel · ↑↓ select · a add"

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
      "#{NumberFormat.compact(usage.last_prompt_tokens)}/#{NumberFormat.compact(usage.total_tokens)}"

    "#{provider}/#{model} · tok #{tokens}"
  end

  defp line(mascot, info, width) do
    hints = hint_spans()
    hints_len = spans_length(hints)
    fixed = String.length(mascot) + 3 + hints_len
    info = truncate(info, max(0, width - fixed - 1))
    pad = max(0, width - String.length(mascot) - 3 - String.length(info) - hints_len)

    spans =
      [
        %Span{content: mascot, style: Theme.style(:status_hot)},
        %Span{content: " · ", style: Theme.style(:status)},
        %Span{content: info, style: Theme.style(:status)},
        %Span{content: String.duplicate(" ", pad), style: Theme.style(:status)}
      ] ++ hints

    %Paragraph{text: [%Line{spans: spans}], style: Theme.style(:status)}
  end

  # Each hint is an accent key "pill" followed by a muted label, e.g. ⟨^C⟩ quit.
  defp hint_spans do
    @key_hints
    |> Enum.map(fn {key, label} ->
      [Theme.key_pill(key), %Span{content: " #{label}", style: Theme.style(:muted)}]
    end)
    |> Enum.intersperse([%Span{content: "  ", style: Theme.style(:status)}])
    |> List.flatten()
  end

  defp spans_length(spans) do
    Enum.reduce(spans, 0, fn %Span{content: content}, acc -> acc + String.length(content) end)
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
