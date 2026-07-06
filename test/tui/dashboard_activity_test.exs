defmodule Beamcore.TUI.Components.DashboardActivityTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.Dashboard
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.{MultiScreenState, Shell, State}
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Table}

  @area %Rect{x: 0, y: 0, width: 120, height: 40}

  defp activity do
    [
      %{
        timestamp_ms: 1_700_000_001_000,
        name: "provider_usage",
        target: nil,
        status: :error,
        label: "provider_usage",
        summary: "Provider usage 1.2k tokens",
        result: nil
      },
      %{
        timestamp_ms: 1_700_000_000_000,
        name: "eeva",
        target: "Elixir",
        status: :done,
        label: "eeva File.ls!",
        summary: "ok",
        result: "ok"
      }
    ]
  end

  defp activity_panel(system) do
    {widget, _rect} =
      Dashboard.panels(system, @area) |> Enum.find(fn {w, _} -> title(w) == "◆ Activity" end)

    widget
  end

  defp title(%{block: %Block{title: title}}), do: title
  defp title(_), do: nil

  defp cell(%{content: content}), do: content

  test "the Activity panel is a native Table with a row per recent event, newest first" do
    system = %{TuiSystem.new(:agent) | activity: activity()}
    table = activity_panel(system)

    assert %Table{block: %Block{title: "◆ Activity"}} = table
    header = Enum.map(table.header, &cell/1)
    assert "kind" in header
    assert "result" in header

    kinds = Enum.map(table.rows, fn [_time, kind | _] -> cell(kind) end)
    assert kinds == ["provider_usage", "eeva"]
  end

  test "each row formats the timestamp and carries the event detail and status" do
    system = %{TuiSystem.new(:agent) | activity: activity()}
    [_provider, eeva_row] = activity_panel(system).rows

    [time, _kind, detail, status] = Enum.map(eeva_row, &cell/1)

    assert time == "22:13:20"
    assert detail =~ "ok"
    assert status =~ "done"
  end

  test "an empty activity list renders an empty-state paragraph" do
    system = %{TuiSystem.new(:agent) | activity: []}
    widget = activity_panel(system)

    assert %Paragraph{block: %Block{title: "◆ Activity"}} = widget
    text = widget.text |> Enum.flat_map(& &1.spans) |> Enum.map_join(" ", & &1.content)
    assert text =~ "no activity"
  end

  test "the shell feeds the chat's activity trace into the dashboard" do
    chat = %{State.new(nil, ExRatatui.textarea_new()) | activity: activity()}

    multi = %MultiScreenState{
      active_mode: :dashboard,
      chat_state: chat,
      dashboard_state: TuiSystem.new(:agent)
    }

    widgets = Shell.render(multi, %Frame{width: 120, height: 40})

    activity_table =
      Enum.find_value(widgets, fn {w, _rect} ->
        match?(%Table{block: %Block{title: "◆ Activity"}}, w) && w
      end)

    assert activity_table
    kinds = Enum.map(activity_table.rows, fn [_time, kind | _] -> cell(kind) end)
    assert "eeva" in kinds
  end
end
