defmodule Beamcore.TUI.DashboardFocusTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.{Dashboard, Providers}
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Theme
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Block

  defp key(code), do: %ExRatatui.Event.Key{code: code, kind: "press", modifiers: []}

  defp activity(n) do
    for i <- 1..n do
      %{
        timestamp_ms: 1_700_000_000_000 + i * 1000,
        name: "evt",
        summary: "e#{i}",
        status: :done,
        label: "evt"
      }
    end
  end

  defp send_key(system, code) do
    {:noreply, updated} = TuiSystem.handle_event(key(code), system)
    updated
  end

  describe "panel focus" do
    test "defaults to the Providers panel" do
      assert TuiSystem.new(:agent).active_panel == :providers
    end

    test "Tab cycles focus between Providers and Activity" do
      system = TuiSystem.new(:agent)

      system = send_key(system, "tab")
      assert system.active_panel == :activity

      system = send_key(system, "tab")
      assert system.active_panel == :providers

      assert send_key(system, "back_tab").active_panel == :activity
    end

    test "Tab is owned by the add-provider form while it is open" do
      providers = %{Providers.new(:agent) | adding?: true, form: Providers.Form.new()}
      system = %{TuiSystem.new(:agent) | providers: providers}

      updated = send_key(system, "tab")

      # focus does not change; the form advanced its field instead
      assert updated.active_panel == :providers
      assert updated.providers.adding?
    end
  end

  describe "activity scrolling" do
    setup do
      system = %{TuiSystem.new(:agent) | activity: activity(20), active_panel: :activity}
      %{system: system}
    end

    test "arrows and paging move the offset, clamped to the trace", %{system: system} do
      system = send_key(system, "down")
      system = send_key(system, "down")
      assert system.activity_offset == 2

      system = send_key(system, "page_down")
      assert system.activity_offset == 7

      system = send_key(system, "end")
      assert system.activity_offset == 19

      # cannot scroll past the end
      assert send_key(system, "down").activity_offset == 19

      system = send_key(system, "home")
      assert system.activity_offset == 0

      # cannot scroll above the top
      assert send_key(system, "up").activity_offset == 0
    end

    test "non-scroll keys are inert while Activity is focused", %{system: system} do
      assert send_key(system, "a").activity_offset == 0
      assert send_key(system, "a").providers == system.providers
    end

    test "Providers-focused arrows never move the Activity offset" do
      system = %{TuiSystem.new(:agent) | activity: activity(20), active_panel: :providers}
      assert send_key(system, "down").activity_offset == 0
    end
  end

  test "clamp_activity_offset caps the offset at the current trace length" do
    system = %{TuiSystem.new(:agent) | activity: activity(3), activity_offset: 15}
    assert TuiSystem.clamp_activity_offset(system).activity_offset == 2

    empty = %{TuiSystem.new(:agent) | activity: [], activity_offset: 5}
    assert TuiSystem.clamp_activity_offset(empty).activity_offset == 0
  end

  describe "rendering reflects focus and scroll" do
    @area %Rect{x: 0, y: 0, width: 120, height: 30}

    defp panel(widgets, title) do
      Enum.find_value(widgets, fn {w, _} ->
        if match?(%{block: %Block{title: ^title}}, w), do: w
      end)
    end

    test "the focused panel's border is accent-styled, the other is not" do
      system = %{TuiSystem.new(:agent) | active_panel: :activity, activity: activity(5)}
      widgets = Dashboard.panels(system, @area)

      assert panel(widgets, "Activity").block.border_style == Theme.style(:accent)
      assert panel(widgets, "Providers").block.border_style == Theme.style(:border)
    end

    test "the Activity table renders the rows at the current scroll offset" do
      system = %{
        TuiSystem.new(:agent)
        | active_panel: :activity,
          activity: activity(30),
          activity_offset: 5
      }

      table = panel(Dashboard.panels(system, @area), "Activity")

      # first visible detail cell is the 6th event (offset 5, zero-based)
      [_time, _kind, detail, _result] = hd(table.rows)
      assert detail.content =~ "e6"
    end
  end
end
