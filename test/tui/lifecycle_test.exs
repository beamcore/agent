defmodule Beamcore.TUI.LifecycleTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Smoke
  alias Beamcore.TUI.TerminalOptions
  alias ExRatatui.Frame

  test "local TUI child is temporary and is not restarted after a crash" do
    assert %{restart: :temporary, start: {TUI, :start_link, [opts]}} = TUI.runtime_child_spec([])
    assert opts[:poll_interval] == 16
    assert opts[:mouse_capture] == false
    assert opts[:focus_events] == false
  end

  test "local terminal defaults avoid risky VTE modes" do
    assert TerminalOptions.defaults() == [
             poll_interval: 16,
             mouse_capture: false,
             focus_events: false
           ]
  end

  test "minimal smoke screen uses the same local terminal startup strategy" do
    smoke_opts = TerminalOptions.apply([])
    main_opts = elem(TUI.runtime_child_spec([]).start, 2) |> hd()

    assert smoke_opts == main_opts
    assert %{start: {Smoke, :start_link, [[]]}} = Smoke.child_spec([])
  end

  test "local terminal modes are configurable without terminal-specific branches" do
    previous = Application.get_env(:beamcore, :tui_terminal)

    try do
      Application.put_env(:beamcore, :tui_terminal, mouse_capture: true)

      opts = TerminalOptions.apply(focus_events: true, poll_interval: 5)

      assert opts[:mouse_capture] == true
      assert opts[:focus_events] == true
      assert opts[:poll_interval] == 5
    after
      restore_tui_terminal(previous)
    end
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

  defp restore_tui_terminal(nil), do: Application.delete_env(:beamcore, :tui_terminal)
  defp restore_tui_terminal(value), do: Application.put_env(:beamcore, :tui_terminal, value)
end
