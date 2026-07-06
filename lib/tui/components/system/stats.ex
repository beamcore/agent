defmodule Beamcore.TUI.Components.System.Stats do
  @moduledoc false

  alias Beamcore.TUI.Components.System.Store
  alias Beamcore.TUI.{NumberFormat, Theme}
  alias ExRatatui.Widgets.{Bar, BarChart}

  @doc "The per-provider token totals as a native horizontal `BarChart`."
  def bar_chart(stats) when is_map(stats) do
    sorted = Enum.sort_by(stats, fn {_name, data} -> -total(data) end)
    max_total = sorted |> Enum.map(fn {_name, data} -> total(data) end) |> Enum.max(fn -> 0 end)

    %BarChart{
      data: Enum.map(sorted, fn {name, data} -> bar(name, total(data), max_total) end),
      direction: :horizontal,
      bar_width: 1,
      bar_gap: 1,
      bar_style: Theme.style(:done),
      value_style: Theme.style(:accent),
      label_style: Theme.style(:muted)
    }
  end

  def snapshot, do: Store.load()

  defp bar(name, total, max_total) do
    %Bar{label: name, value: total, text_value: fmt(total), style: bar_style(total, max_total)}
  end

  defp total(data), do: Map.get(data, "total_tokens", 0) || 0

  defp bar_style(total, max) when total == max and max > 0, do: Theme.style(:status_hot)
  defp bar_style(_total, _max), do: Theme.style(:done)

  defp fmt(0), do: "0"
  defp fmt(n) when is_integer(n), do: NumberFormat.compact(n)
  defp fmt(n), do: to_string(n)
end
