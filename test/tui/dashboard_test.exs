defmodule Beamcore.TUI.Components.DashboardTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.{Dashboard, Providers}
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Components.System.Mesh
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Scrollbar}

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

  # The Eeva line is the only borderless Paragraph in the tree.
  defp eeva(widgets) do
    Enum.find(widgets, fn {w, _rect} -> match?(%Paragraph{block: nil}, w) end)
  end

  defp scrollbars(widgets), do: Enum.filter(widgets, fn {w, _} -> match?(%Scrollbar{}, w) end)

  defp within_bounds?({_widget, %Rect{} = r}, %Rect{} = area) do
    r.width > 0 and r.height > 0 and
      r.x >= area.x and r.y >= area.y and
      r.x + r.width <= area.x + area.width and
      r.y + r.height <= area.y + area.height
  end

  @titled_panels ["Token Usage", "Providers", "Activity", "Mesh"]

  test "a wide area renders the four titled panels plus a borderless Eeva line" do
    area = %Rect{x: 0, y: 1, width: 120, height: 30}
    widgets = Dashboard.panels(sample_system(), area)

    assert titles(widgets) == @titled_panels
    assert eeva(widgets)

    for {w, _rect} <- widgets, title(w) != nil do
      assert %Block{borders: [:all], border_type: :rounded} = w.block
    end

    assert Enum.all?(widgets, &within_bounds?(&1, area))
  end

  test "a wide grid stacks a two-column top, full-width Activity and Mesh, and a 1-row Eeva" do
    area = %Rect{x: 0, y: 0, width: 120, height: 30}
    widgets = Dashboard.panels(sample_system(), area)

    usage = panel_rect(widgets, "Token Usage")
    providers = panel_rect(widgets, "Providers")
    activity = panel_rect(widgets, "Activity")
    mesh = panel_rect(widgets, "Mesh")
    {_w, eeva} = eeva(widgets)

    # top row: two columns sharing a y
    assert usage.y == providers.y
    assert providers.x > usage.x

    # Activity and Mesh span the full width, stacked below the top row
    assert activity.x == area.x and activity.width == area.width
    assert mesh.x == area.x and mesh.width == area.width
    assert activity.y > usage.y
    assert mesh.y > activity.y

    # Eeva is a single full-width row at the very bottom
    assert eeva.height == 1
    assert eeva.width == area.width
    assert eeva.y > mesh.y
  end

  test "a narrow area stacks every panel in a single full-width column" do
    area = %Rect{x: 0, y: 0, width: 60, height: 40}
    widgets = Dashboard.panels(sample_system(), area)

    assert titles(widgets) == @titled_panels
    assert eeva(widgets)

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
        if title(w) == "Token Usage", do: w
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

      providers_rect = panel_rect(widgets, "Providers")
      inner_h = providers_rect.height - 2

      form = Enum.find_value(widgets, fn {w, _} -> if title(w) == "Providers", do: w end)
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
      activity_rect = panel_rect(widgets, "Activity")
      inner_h = activity_rect.height - 2

      table = Enum.find_value(widgets, fn {w, _} -> if title(w) == "Activity", do: w end)
      # rows (excluding the header) never exceed the visible area
      assert length(table.rows) <= inner_h - 1

      assert Enum.any?(scrollbars(widgets), fn {_sb, r} ->
               r.x == activity_rect.x + activity_rect.width - 1
             end)
    end
  end
end
