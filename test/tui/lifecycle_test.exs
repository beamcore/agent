defmodule Beamcore.TUI.LifecycleTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI
  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Smoke
  alias Beamcore.TUI.TerminalOptions
  alias ExRatatui.Frame

  @repo_root Path.expand("../..", __DIR__)

  test "interactive TUI starts directly instead of through a supervisor" do
    tui_source = File.read!(Path.expand("../../lib/tui/tui.ex", __DIR__))
    app_source = File.read!(Path.expand("../../lib/beamcore/agent/agent.ex", __DIR__))

    refute tui_source =~ "DynamicSupervisor.start_child"
    refute tui_source =~ "runtime_child_spec"
    refute app_source =~ "Beamcore.TUI.DynamicSupervisor"
  end

  test "local terminal defaults defer to ExRatatui" do
    assert TerminalOptions.defaults() == []
    assert TerminalOptions.apply([]) == []
  end

  test "minimal smoke screen uses the same local terminal startup strategy" do
    smoke_opts = TerminalOptions.apply([])
    main_opts = TerminalOptions.apply([])

    assert smoke_opts == main_opts
    assert %{start: {Smoke, :start_link, [[]]}} = Smoke.child_spec([])
  end

  test "textarea smoke uses the same local terminal startup strategy and native textarea path" do
    assert {:ok, state} = Smoke.mount(mode: :textarea, size: {80, 24})
    assert state.mode == :textarea
    assert is_reference(state.textarea)

    {:noreply, updated} =
      Smoke.handle_event(%ExRatatui.Event.Key{code: "a", kind: "press", modifiers: []}, state)

    assert updated.text == "a"

    frame = %Frame{width: 80, height: 24}

    assert [{%ExRatatui.Widgets.Paragraph{}, _}, {%ExRatatui.Widgets.Textarea{}, _}] =
             Smoke.render(updated, frame)
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

  test "F3 system header renders as a bounded control grid" do
    lines = TuiSystem.render_text(TuiSystem.new(:agent), 32, 24)
    text = lines |> Enum.flat_map(& &1.spans) |> Enum.map_join("", & &1.content)

    assert text =~ "BEAMCORE CONTROL GRID"
    assert text =~ "F3 // providers // mcp"
    assert Enum.all?(Enum.take(lines, 5), fn line -> rendered_line_length(line) <= 32 end)
  end

  test "F3 render stays bounded in a narrow terminal" do
    lines = TuiSystem.render_text(TuiSystem.new(:agent), 24, 12)

    assert length(lines) <= 12
    assert Enum.all?(lines, fn line -> rendered_line_length(line) <= 24 end)
  end

  test "F3 provider form stays bounded in a narrow terminal" do
    system = TuiSystem.new(:agent)

    {:noreply, system} =
      TuiSystem.handle_event(
        %ExRatatui.Event.Key{code: "a", kind: "press", modifiers: []},
        system
      )

    lines = TuiSystem.render_text(system, 24, 12)

    assert length(lines) <= 12
    assert Enum.all?(lines, fn line -> rendered_line_length(line) <= 24 end)
  end

  test "F3 supports arrow key scrolling when provider selection is at an edge" do
    system =
      :agent
      |> TuiSystem.new()
      |> Map.put(:providers, %Providers{providers: [], active_provider: nil})
      |> TuiSystem.set_viewport_height(8)

    state = %Beamcore.TUI.MultiScreenState{
      active_screen: :f3,
      f1_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f2_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f3_state: system
    }

    {:noreply, scrolled} =
      TUI.handle_event(%ExRatatui.Event.Key{code: "down", kind: "press", modifiers: []}, state)

    assert scrolled.f3_state.scroll_offset == 1

    {:noreply, top} =
      TUI.handle_event(%ExRatatui.Event.Key{code: "up", kind: "press", modifiers: []}, scrolled)

    assert top.f3_state.scroll_offset == 0
  end

  test "F3 supports page key scrolling" do
    system =
      :agent
      |> TuiSystem.new()
      |> TuiSystem.set_viewport_height(8)

    state = %Beamcore.TUI.MultiScreenState{
      active_screen: :f3,
      f1_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f2_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f3_state: system
    }

    {:noreply, scrolled} =
      TUI.handle_event(
        %ExRatatui.Event.Key{code: "page_down", kind: "press", modifiers: []},
        state
      )

    assert scrolled.f3_state.scroll_offset > 0

    {:noreply, top} =
      TUI.handle_event(%ExRatatui.Event.Key{code: "home", kind: "press", modifiers: []}, scrolled)

    assert top.f3_state.scroll_offset == 0
  end

  test "F3 ignores mouse wheel scrolling" do
    system =
      :agent
      |> TuiSystem.new()
      |> TuiSystem.set_viewport_height(8)

    state = %Beamcore.TUI.MultiScreenState{
      active_screen: :f3,
      f1_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f2_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f3_state: system
    }

    {:noreply, scrolled} =
      TUI.handle_event(%ExRatatui.Event.Mouse{kind: "scroll_down", x: 0, y: 0}, state)

    assert scrolled.f3_state.scroll_offset == 0
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
      |> TuiSystem.render_text(100, 80)
      |> Enum.flat_map(& &1.spans)
      |> Enum.map_join("", & &1.content)

    assert text =~ "provider-a"
    assert text =~ "Mesh"
  end

  test "F3 renders MCP rail and toggles the runtime flag" do
    previous_enabled = Application.get_env(:beamcore, :mcp_enabled)
    previous_config_enabled = Beamcore.Config.get(:mcp_enabled)

    Application.put_env(:beamcore, :mcp_enabled, false)
    Beamcore.Config.delete(:mcp_enabled)

    on_exit(fn ->
      restore_mcp_app_env(previous_enabled)
      restore_mcp_config(previous_config_enabled)
    end)

    system = TuiSystem.new(:agent)
    text = system |> TuiSystem.render_text(80, 80) |> rendered_text()

    assert text =~ "MCP"
    assert text =~ "standby"
    assert text =~ "no server autostart"

    {:noreply, enabled} =
      TuiSystem.handle_event(
        %ExRatatui.Event.Key{code: "m", kind: "press", modifiers: []},
        system
      )

    assert enabled.mcp_snapshot.enabled?
    assert Beamcore.MCP.Config.enabled?()
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

  test "idle real TUI state does not run a permanent tick loop" do
    state = %Beamcore.TUI.MultiScreenState{
      active_screen: :f1,
      f1_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f2_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f3_state: TuiSystem.new(:agent)
    }

    {:noreply, updated} =
      TUI.handle_event(%ExRatatui.Event.Key{code: "a", kind: "press", modifiers: []}, state)

    assert updated.tick_ref == nil
    assert ExRatatui.textarea_get_value(updated.f1_state.textarea) == "a"
  end

  test "F3 arms a bounded self-rearming tick for mesh refresh" do
    state = %Beamcore.TUI.MultiScreenState{
      active_screen: :f1,
      f1_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f2_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f3_state: TuiSystem.new(:agent)
    }

    {:noreply, updated} =
      TUI.handle_event(%ExRatatui.Event.Key{code: "f3", kind: "press", modifiers: []}, state)

    assert updated.active_screen == :f3
    assert is_reference(updated.tick_ref)
  end

  test "stale tick messages are ignored without rendering" do
    state = %Beamcore.TUI.MultiScreenState{
      active_screen: :f1,
      f1_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f2_state: Beamcore.TUI.State.new(nil, ExRatatui.textarea_new()),
      f3_state: TuiSystem.new(:agent),
      tick_ref: make_ref()
    }

    assert {:noreply, ^state, [render?: false]} = TUI.handle_info({:tick, make_ref()}, state)
  end

  test "TUI runtime does not use unconditional interval timers" do
    tui_sources =
      "lib/tui"
      |> Path.expand(@repo_root)
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    refute tui_sources =~ ":timer.send_interval"
    refute tui_sources =~ "send_interval("
  end

  test "chat render is cached independently from input changes" do
    render_source = File.read!(Path.expand("../../lib/tui/render.ex", __DIR__))

    assert render_source =~ "cached_chat_widget"
    assert render_source =~ "state.messages"
    assert render_source =~ "state.scroll_offset"
    refute render_source =~ "state.textarea"
  end

  defp restore_tui_terminal(nil), do: Application.delete_env(:beamcore, :tui_terminal)
  defp restore_tui_terminal(value), do: Application.put_env(:beamcore, :tui_terminal, value)

  defp restore_mcp_app_env(nil), do: Application.delete_env(:beamcore, :mcp_enabled)
  defp restore_mcp_app_env(value), do: Application.put_env(:beamcore, :mcp_enabled, value)

  defp restore_mcp_config(nil), do: Beamcore.Config.delete(:mcp_enabled)
  defp restore_mcp_config(value), do: Beamcore.Config.put(:mcp_enabled, value)

  defp rendered_line_length(line) do
    line.spans
    |> Enum.map(&String.length(&1.content || ""))
    |> Enum.sum()
  end

  defp rendered_text(lines) do
    lines
    |> Enum.flat_map(& &1.spans)
    |> Enum.map_join("", & &1.content)
  end
end
