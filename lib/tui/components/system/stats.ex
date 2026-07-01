defmodule Beamcore.TUI.Components.System.Stats do
  @moduledoc false

  alias Beamcore.TUI.Components.System.{Section, Store}
  alias Beamcore.TUI.{NumberFormat, Theme}
  alias ExRatatui.Text.{Line, Span}

  @bar_max 20
  @bar_full "█"
  @bar_empty "░"

  def render(width) do
    render(snapshot(), width)
  end

  def render(stats, width) when is_map(stats) do
    content = build_content(stats, width)
    Section.section("Token Usage", content, width, icon: "◈")
  end

  def snapshot, do: Store.load()

  defp build_content(stats, width) do
    accent = Theme.style(:accent)
    muted = Theme.style(:muted)
    subtle = Theme.style(:subtle)
    inner = width - 10

    if map_size(stats) == 0 do
      [%Line{spans: [%Span{content: "  no usage recorded yet", style: muted}]}]
    else
      max_total =
        stats
        |> Enum.map(fn {_, v} -> Map.get(v, "total_tokens", 0) || 0 end)
        |> Enum.max(fn -> 1 end)

      header = [
        %Line{
          spans: [
            %Span{content: "  #{pad("provider", 12)}", style: muted},
            %Span{content: pad("input", 9), style: muted},
            %Span{content: pad("output", 9), style: muted},
            %Span{content: pad("total", 9), style: muted},
            %Span{content: pad("consumption", @bar_max + 3), style: muted},
            %Span{content: "last used", style: muted}
          ]
        },
        %Line{
          spans: [%Span{content: "  #{String.duplicate("─", max(inner - 3, 4))}", style: subtle}]
        }
      ]

      rows =
        stats
        |> Enum.sort_by(fn {_, v} -> -(Map.get(v, "total_tokens", 0) || 0) end)
        |> Enum.map(fn {name, data} ->
          inp = fmt(Map.get(data, "input_tokens", 0))
          out = fmt(Map.get(data, "output_tokens", 0))
          tot = Map.get(data, "total_tokens", 0) || 0
          last = fmt_time(Map.get(data, "last_used"))
          bar = bar_chart(tot, max_total, @bar_max)

          %Line{
            spans: [
              %Span{content: "  #{pad(name, 12)}", style: Theme.style(:base)},
              %Span{content: pad(inp, 9), style: Theme.style(:done)},
              %Span{content: pad(out, 9), style: Theme.style(:done)},
              %Span{content: pad(fmt(tot), 9), style: accent},
              %Span{content: " #{bar} ", style: bar_style(tot, max_total)},
              %Span{content: last, style: subtle}
            ]
          }
        end)

      header ++ rows
    end
  end

  defp bar_chart(value, max_value, max_width) do
    filled =
      if max_value > 0,
        do: round(value / max_value * max_width),
        else: 0

    filled = min(filled, max_width)
    String.duplicate(@bar_full, filled) <> String.duplicate(@bar_empty, max_width - filled)
  end

  defp bar_style(value, max) when value == max, do: Theme.style(:status_hot)
  defp bar_style(_, _), do: Theme.style(:done)

  defp fmt(nil), do: "0"
  defp fmt(0), do: "0"
  defp fmt(n) when is_integer(n), do: NumberFormat.compact(n)
  defp fmt(n), do: to_string(n)

  defp fmt_time(nil), do: "—"

  defp fmt_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %d %H:%M")
      _ -> "—"
    end
  end

  defp fmt_time(_), do: "—"

  defp pad(text, width) do
    text = to_string(text)
    if String.length(text) >= width, do: text, else: String.pad_trailing(text, width)
  end
end
