defmodule Beamcore.TUI.Components.DashboardTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.{Dashboard, Providers}
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Components.System.Mesh
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Scrollbar}

  defp sample_system do
    %{
      TuiSystem.new(:agent)
      | mesh_snapshot: Mesh.local_snapshot(),
        stats_snapshot: %{
          "provider-a" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "total_tokens" => 15,
            "last_used" => "2026-06-24T00:00:00Z"
          }
        }
    }
  end

  defp title(%{block: %Block{title: t}}), do: t
  defp title(_), do: nil

  defp titles(widgets), do: for({w, _rect} <- widgets, t = title(w), do: t)

  defp panel_rect(widgets, title) do
    Enum.find_value(widgets, fn {w, rect} -> if title(w) == title, do: rect end)
  end

  defp scrollbars(widgets), do: Enum.filter(widgets, fn {w, _} -> match?(%Scrollbar{}, w) end)

  defp within_bounds?({_widget, %Rect{} = r}, %Rect{} = area) do
    r.width > 0 and r.height > 0 and
      r.x >= area.x and r.y >= area.y and
      r.x + r.width <= area.x + area.width and
      r.y + r.height <= area.y + area.height
  end

  @titled_panels ["◆ Token Usage", "◆ Providers", "◆ Activity", "◆ Mesh", "◆ Eeva Runtime"]

  test "a wide area renders the five titled panels including a boxed Eeva Runtime" do
    area = %Rect{x: 0, y: 1, width: 120, height: 30}
    widgets = Dashboard.panels(sample_system(), area)

    assert titles(widgets) == @titled_panels

    for {w, _rect} <- widgets, title(w) != nil do
      assert %Block{borders: [:all], border_type: :rounded} = w.block
    end

    assert Enum.all?(widgets, &within_bounds?(&1, area))
  end

  test "a wide grid stacks a two-column top, full-width Activity, and a Mesh|Eeva bottom row" do
    area = %Rect{x: 0, y: 0, width: 120, height: 30}
    widgets = Dashboard.panels(sample_system(), area)

    usage = panel_rect(widgets, "◆ Token Usage")
    providers = panel_rect(widgets, "◆ Providers")
    activity = panel_rect(widgets, "◆ Activity")
    mesh = panel_rect(widgets, "◆ Mesh")
    eeva = panel_rect(widgets, "◆ Eeva Runtime")

    # top row: two columns sharing a y
    assert usage.y == providers.y
    assert providers.x > usage.x

    # Activity spans the full width, below the top row
    assert activity.x == area.x and activity.width == area.width
    assert activity.y > usage.y

    # bottom row: Mesh and Eeva share a row, side by side, below Activity
    assert mesh.y == eeva.y
    assert mesh.x == area.x
    assert eeva.x > mesh.x
    assert mesh.width < area.width
    assert mesh.y > activity.y
  end

  test "a non-unicode terminal falls back to ASCII framing and status glyphs" do
    activity = [
      %{
        timestamp_ms: 1_700_000_000_000,
        name: "run",
        summary: "did a thing",
        status: :done,
        label: "run"
      }
    ]

    system = %{sample_system() | unicode?: false, activity: activity}
    area = %Rect{x: 0, y: 0, width: 120, height: 30}
    widgets = Dashboard.panels(system, area)

    assert titles(widgets) == [
             "* Token Usage",
             "* Providers",
             "* Activity",
             "* Mesh",
             "* Eeva Runtime"
           ]

    for {w, _rect} <- widgets, title(w) != nil do
      assert w.block.border_type == :plain
    end

    table = Enum.find_value(widgets, fn {w, _} -> if title(w) == "* Activity", do: w end)
    [row | _] = table.rows
    assert List.last(row).content == "v done"

    # The ASCII path must actually draw, not just shape the structs.
    terminal = ExRatatui.init_test_terminal(120, 30)
    on_exit(fn -> ExRatatui.Native.restore_terminal(terminal) end)
    assert :ok = ExRatatui.draw(terminal, widgets)
  end

  test "a narrow area stacks every panel in a single full-width column" do
    area = %Rect{x: 0, y: 0, width: 60, height: 40}
    widgets = Dashboard.panels(sample_system(), area)

    assert titles(widgets) == @titled_panels

    for {_widget, %Rect{} = r} <- widgets do
      assert r.x == area.x
      assert r.width == area.width
    end

    assert Enum.all?(widgets, &within_bounds?(&1, area))
  end

  test "the token-usage panel charts recorded provider stats" do
    area = %Rect{x: 0, y: 0, width: 120, height: 30}

    usage =
      Enum.find_value(Dashboard.panels(sample_system(), area), fn {w, _} ->
        if title(w) == "◆ Token Usage", do: w
      end)

    assert "provider-a" in Enum.map(usage.data, & &1.label)
  end

  test "renders every panel with empty data and draws without crashing" do
    system = %{TuiSystem.new(:agent) | stats_snapshot: %{}, mesh_snapshot: Mesh.local_snapshot()}
    area = %Rect{x: 0, y: 0, width: 120, height: 30}

    widgets = Dashboard.panels(system, area)
    assert titles(widgets) == @titled_panels
    # Content fits, so no scrollbars appear.
    assert scrollbars(widgets) == []

    terminal = ExRatatui.init_test_terminal(120, 30)
    on_exit(fn -> ExRatatui.Native.restore_terminal(terminal) end)
    assert :ok = ExRatatui.draw(terminal, widgets)
  end

  describe "overflow scrollbars" do
    test "the add-provider form windows to the panel and shows a scrollbar" do
      providers = %{Providers.new(:agent) | adding?: true, form: Providers.Form.new()}
      system = %{TuiSystem.new(:agent) | providers: providers}
      area = %Rect{x: 0, y: 0, width: 120, height: 30}

      widgets = Dashboard.panels(system, area)

      providers_rect = panel_rect(widgets, "◆ Providers")
      inner_h = providers_rect.height - 2

      form = Enum.find_value(widgets, fn {w, _} -> if title(w) == "◆ Providers", do: w end)
      assert length(form.text) <= inner_h

      # a scrollbar is drawn on the Providers panel's right edge
      assert Enum.any?(scrollbars(widgets), fn {_sb, r} ->
               r.x == providers_rect.x + providers_rect.width - 1
             end)
    end

    test "a long activity log windows to the panel and shows a scrollbar" do
      activity =
        for i <- 1..40 do
          %{
            timestamp_ms: 1_700_000_000_000 + i * 1000,
            name: "model_context",
            summary: "detail #{i}",
            status: :done,
            label: "model_context"
          }
        end

      system = %{TuiSystem.new(:agent) | activity: activity}
      area = %Rect{x: 0, y: 0, width: 120, height: 30}

      widgets = Dashboard.panels(system, area)
      activity_rect = panel_rect(widgets, "◆ Activity")
      inner_h = activity_rect.height - 2

      table = Enum.find_value(widgets, fn {w, _} -> if title(w) == "◆ Activity", do: w end)
      # rows (excluding the header) never exceed the visible area
      assert length(table.rows) <= inner_h - 1

      assert Enum.any?(scrollbars(widgets), fn {_sb, r} ->
               r.x == activity_rect.x + activity_rect.width - 1
             end)
    end
  end
end
