defmodule Beamcore.TUI.Components.DashboardUsageTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.Dashboard
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Components.System.Stats
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{BarChart, Block, Paragraph}

  @stats %{
    "mistral" => %{
      "total_tokens" => 81_100,
      "input_tokens" => 76_600,
      "output_tokens" => 4_400
    },
    "openai" => %{"total_tokens" => 1_200, "input_tokens" => 1_000, "output_tokens" => 200}
  }

  describe "Stats.bar_chart/1" do
    test "builds one horizontal bar per provider, largest total first" do
      chart = Stats.bar_chart(@stats)

      assert %BarChart{direction: :horizontal} = chart
      assert Enum.map(chart.data, & &1.label) == ["mistral", "openai"]
      assert Enum.map(chart.data, & &1.value) == [81_100, 1_200]
    end

    test "labels each bar with a human-formatted total" do
      [mistral, openai] = Stats.bar_chart(@stats).data

      assert mistral.text_value == "81.1k"
      assert openai.text_value == "1.2k"
    end
  end

  describe "the Token Usage dashboard panel" do
    defp usage_panel(system) do
      area = %Rect{x: 0, y: 0, width: 120, height: 30}
      {widget, _rect} = Dashboard.panels(system, area) |> Enum.at(0)
      widget
    end

    test "is a native BarChart wrapped in the Token Usage block when usage exists" do
      system = %{TuiSystem.new(:agent) | stats_snapshot: @stats}

      assert %BarChart{block: %Block{title: "Token Usage"}} = usage_panel(system)
    end

    test "falls back to an empty-state paragraph when no usage is recorded" do
      system = %{TuiSystem.new(:agent) | stats_snapshot: %{}}
      widget = usage_panel(system)

      assert %Paragraph{block: %Block{title: "Token Usage"}} = widget
      text = widget.text |> Enum.flat_map(& &1.spans) |> Enum.map_join(" ", & &1.content)
      assert text =~ "no usage"
    end
  end
end
