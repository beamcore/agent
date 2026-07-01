defmodule Beamcore.TUI.Components.DashboardMeshTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.Dashboard
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Components.System.Mesh
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Canvas}
  alias ExRatatui.Widgets.Canvas.{Circle, Label, Line, Points}

  defp peer(name), do: %{short_name: name, memory: 50_000_000, process_count: 5}

  defp two_peer_snapshot do
    %{
      self_info: %{short_name: "core", memory: 100_000_000, process_count: 10},
      peers: [peer("peer-a"), peer("peer-b")],
      epmd_names: %{"core" => 1, "peer-a" => 2, "peer-b" => 3},
      total_memory: 200_000_000,
      total_processes: 20
    }
  end

  defp shapes_of(%Canvas{shapes: shapes}, mod), do: Enum.filter(shapes, &(&1.__struct__ == mod))

  describe "Mesh.canvas/1" do
    test "draws a braille self node with its name label" do
      canvas = Mesh.canvas(Mesh.local_snapshot())

      assert %Canvas{marker: :braille} = canvas
      assert shapes_of(canvas, Circle) != []

      labels = canvas |> shapes_of(Label) |> Enum.map(& &1.text)
      assert Mesh.local_snapshot().self_info.short_name in labels
    end

    test "a lone node has no link lines" do
      assert shapes_of(Mesh.canvas(Mesh.local_snapshot()), Line) == []
    end

    test "each peer gets a link line, a point, and a name label" do
      canvas = Mesh.canvas(two_peer_snapshot())

      assert length(shapes_of(canvas, Line)) == 2
      assert length(shapes_of(canvas, Points)) == 2

      labels = canvas |> shapes_of(Label) |> Enum.map(& &1.text)
      assert "peer-a" in labels
      assert "peer-b" in labels
    end
  end

  describe "Mesh.summary/1" do
    test "captions peers, epmd, memory and processes" do
      summary = Mesh.summary(two_peer_snapshot())

      assert summary =~ "peers 2"
      assert summary =~ "epmd 3"
      assert summary =~ "procs 20"
    end
  end

  describe "the Mesh dashboard panel" do
    test "is a native Canvas wrapped in the Mesh block with a stats caption" do
      system = %{TuiSystem.new(:agent) | mesh_snapshot: two_peer_snapshot()}
      area = %Rect{x: 0, y: 0, width: 120, height: 30}
      {widget, _rect} = Dashboard.panels(system, area) |> Enum.at(2)

      assert %Canvas{block: %Block{title: "Mesh"}} = widget

      caption =
        widget.block.titles
        |> Enum.filter(&(&1.position == :bottom))
        |> Enum.map_join(" ", & &1.content)

      assert caption =~ "peers 2"
    end
  end
end
