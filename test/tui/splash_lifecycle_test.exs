defmodule Beamcore.TUI.SplashLifecycleTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.{MultiScreenState, Shell, State}
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.BigText

  defp key(code), do: %ExRatatui.Event.Key{code: code, kind: "press", modifiers: []}

  defp splashing(overrides \\ []) do
    Map.merge(
      %MultiScreenState{
        active_mode: :chat,
        chat_state: State.new(nil, ExRatatui.textarea_new()),
        dashboard_state: TuiSystem.new(:agent),
        splash?: true,
        splash_step: 0,
        splash_started_at: System.monotonic_time(:millisecond)
      },
      Map.new(overrides)
    )
  end

  test "the shell renders the splash wordmark while the splash is active" do
    widgets = Shell.render(splashing(), %Frame{width: 100, height: 30})
    assert Enum.any?(widgets, fn {w, _} -> match?(%BigText{}, w) end)
  end

  test "the shell renders the normal scene once the splash is dismissed" do
    widgets = Shell.render(splashing(splash?: false), %Frame{width: 100, height: 30})
    refute Enum.any?(widgets, fn {w, _} -> match?(%BigText{}, w) end)
  end

  test "any keypress skips the splash" do
    {:noreply, dismissed} = TUI.handle_event(key("a"), splashing())
    refute dismissed.splash?
  end

  test "a tick advances the sweep and keeps the splash up before the hold elapses" do
    {:noreply, advanced} = TUI.handle_info(:splash_tick, splashing(splash_step: 1))
    assert advanced.splash?
    assert advanced.splash_step == 2
  end

  test "the splash auto-dismisses once the hold has elapsed" do
    started = System.monotonic_time(:millisecond) - 5_000
    {:noreply, dismissed} = TUI.handle_info(:splash_tick, splashing(splash_started_at: started))
    refute dismissed.splash?
  end
end
