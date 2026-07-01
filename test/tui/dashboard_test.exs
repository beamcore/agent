defmodule Beamcore.TUI.Components.DashboardTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.Dashboard
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Components.System.Mesh
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Block

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

  defp titles(panels) do
    Enum.map(panels, fn {%{block: %Block{title: title}}, _rect} -> title end)
  end

  defp within_bounds?({_widget, %Rect{} = r}, %Rect{} = area) do
    r.width > 0 and r.height > 0 and
      r.x >= area.x and r.y >= area.y and
      r.x + r.width <= area.x + area.width and
      r.y + r.height <= area.y + area.height
  end

  @panel_titles ["Token Usage", "Providers", "Activity", "Mesh", "Eeva Runtime"]

  test "a wide area renders the five native-bordered panels in a grid" do
    area = %Rect{x: 0, y: 1, width: 120, height: 30}
    panels = Dashboard.panels(sample_system(), area)

    assert length(panels) == 5
    assert titles(panels) == @panel_titles

    for {widget, _rect} <- panels do
      assert %Block{borders: [:all], border_type: :rounded} = widget.block
    end

    assert Enum.all?(panels, &within_bounds?(&1, area))
  end

  test "a wide grid places two columns above and below a full-width activity band" do
    area = %Rect{x: 0, y: 0, width: 120, height: 30}
    [usage, providers, activity, mesh, eeva] = Dashboard.panels(sample_system(), area)

    # top row shares a y, bottom row shares a lower y
    assert elem(usage, 1).y == elem(providers, 1).y
    assert elem(mesh, 1).y == elem(eeva, 1).y
    assert elem(mesh, 1).y > elem(usage, 1).y

    # each side row splits into a left and a right column
    assert elem(providers, 1).x > elem(usage, 1).x
    assert elem(eeva, 1).x > elem(mesh, 1).x

    # the activity band sits between the rows and spans the full width
    assert elem(activity, 1).x == area.x
    assert elem(activity, 1).width == area.width
    assert elem(activity, 1).y > elem(usage, 1).y
    assert elem(mesh, 1).y > elem(activity, 1).y
  end

  test "a narrow area stacks the panels in a single full-width column" do
    area = %Rect{x: 0, y: 0, width: 60, height: 40}
    panels = Dashboard.panels(sample_system(), area)

    assert length(panels) == 5
    assert titles(panels) == @panel_titles

    for {_widget, %Rect{} = r} <- panels do
      assert r.x == area.x
      assert r.width == area.width
    end

    assert Enum.all?(panels, &within_bounds?(&1, area))
  end

  test "the token-usage panel charts recorded provider stats" do
    area = %Rect{x: 0, y: 0, width: 120, height: 30}
    {usage, _rect} = Dashboard.panels(sample_system(), area) |> Enum.at(0)

    assert "provider-a" in Enum.map(usage.data, & &1.label)
  end

  test "renders every panel with empty data without crashing" do
    system = %{TuiSystem.new(:agent) | stats_snapshot: %{}, mesh_snapshot: Mesh.local_snapshot()}
    area = %Rect{x: 0, y: 0, width: 120, height: 30}

    panels = Dashboard.panels(system, area)

    assert length(panels) == 5
    assert titles(panels) == @panel_titles
  end
end
