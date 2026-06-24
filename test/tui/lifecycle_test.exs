defmodule Beamcore.TUI.LifecycleTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias ExRatatui.Frame

  test "local TUI child is temporary and is not restarted after a crash" do
    assert %{restart: :temporary, start: {TUI, :start_link, [[]]}} = TUI.runtime_child_spec([])
  end

  test "render exceptions are contained inside the TUI frame" do
    bad_state = %{screen_type: :unknown_screen}
    frame = %Frame{width: 80, height: 24}

    [{%ExRatatui.Widgets.Paragraph{text: text}, rect}] = TUI.render(bad_state, frame)

    assert text =~ "Render"
    assert rect.width == 80
    assert rect.height == 24
  end

  test "F3 render survives tiny resize frames" do
    frame = %Frame{width: 1, height: 1}

    assert [{_widget, rect} | _] = TUI.render(TuiSystem.new(:agent), frame)
    assert rect.width == 1
    assert rect.height == 1
  end

  test "F3 render uses cached stats and mesh snapshots" do
    system = %{
      TuiSystem.new(:agent)
      | mesh_snapshot: Beamcore.TUI.Components.System.Mesh.local_snapshot(),
        stats_snapshot: %{
          "provider-a" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "total_tokens" => 15,
            "last_used" => "2026-06-24T00:00:00Z"
          }
        }
    }

    text =
      system
      |> TuiSystem.render_text(100, 24)
      |> Enum.flat_map(& &1.spans)
      |> Enum.map_join("", & &1.content)

    assert text =~ "provider-a"
    assert text =~ "Mesh Topology"
  end

  test "resize schedules a debounced redraw instead of rendering immediately" do
    state = %Beamcore.TUI.MultiScreenState{
      active_screen: :f3,
      f1_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f2_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f3_state: TuiSystem.new(:agent)
    }

    assert {:noreply, resized, [render?: false]} =
             TUI.handle_event(%ExRatatui.Event.Resize{width: 80, height: 16}, state)

    assert is_reference(resized.resize_redraw_ref)
    assert_receive {:resize_redraw, ref}, 50

    assert {:noreply, settled} = TUI.handle_info({:resize_redraw, ref}, resized)
    assert settled.resize_redraw_ref == nil
  end
end
