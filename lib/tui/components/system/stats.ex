defmodule Beamcore.TUI.Components.System.Stats do
  @moduledoc false

  alias Beamcore.TUI.Components.System.Store
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias Number.SI

  def render(width) do
    accent = Theme.style(:accent)
    muted = Theme.style(:muted)
    subtle = Theme.style(:subtle)
    base = Theme.style(:base)
    done = Theme.style(:done)
    sep = String.duplicate("─", max(width - 6, 4))

    stats = Store.load()

    header = [
      %Line{spans: [%Span{content: "  Token Usage", style: accent}]},
      %Line{spans: [%Span{content: "  #{sep}", style: subtle}]}
    ]

    if map_size(stats) == 0 do
      header ++ [%Line{spans: [%Span{content: "    no usage recorded yet", style: muted}]}]
    else
      table_header = [
        %Line{
          spans: [
            %Span{content: "    #{pad("provider", 14)}", style: muted},
            %Span{content: pad("input", 10), style: muted},
            %Span{content: pad("output", 10), style: muted},
            %Span{content: pad("total", 10), style: muted},
            %Span{content: "last used", style: muted}
          ]
        },
        %Line{spans: [%Span{content: "  #{sep}", style: subtle}]}
      ]

      rows =
        stats
        |> Enum.sort_by(fn {_, v} -> -(Map.get(v, "total_tokens", 0) || 0) end)
        |> Enum.map(fn {name, data} ->
          inp = fmt_tokens(Map.get(data, "input_tokens", 0))
          out = fmt_tokens(Map.get(data, "output_tokens", 0))
          tot = fmt_tokens(Map.get(data, "total_tokens", 0))
          last = fmt_time(Map.get(data, "last_used"))

          %Line{
            spans: [
              %Span{content: "    #{pad(name, 14)}", style: base},
              %Span{content: pad(inp, 10), style: done},
              %Span{content: pad(out, 10), style: done},
              %Span{content: pad(tot, 10), style: accent},
              %Span{content: last, style: subtle}
            ]
          }
        end)

      header ++ table_header ++ rows
    end
  end

  defp fmt_tokens(nil), do: "0"
  defp fmt_tokens(0), do: "0"
  defp fmt_tokens(n) when is_integer(n), do: SI.number_to_si(n, precision: 1, trim: true)
  defp fmt_tokens(n), do: to_string(n)

  defp fmt_time(nil), do: "—"

  defp fmt_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%b %d %H:%M")

      _ ->
        "—"
    end
  end

  defp fmt_time(_), do: "—"

  defp pad(text, width) do
    text = to_string(text)
    if String.length(text) >= width, do: text, else: String.pad_trailing(text, width)
  end
end
