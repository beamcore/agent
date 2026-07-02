defmodule Beamcore.TUI.GlobalCtrlCTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.{MultiScreenState, Shell, State}
  alias ExRatatui.Frame

  defp key(code, mods \\ []), do: %ExRatatui.Event.Key{code: code, kind: "press", modifiers: mods}
  defp ctrl_c, do: key("c", ["ctrl"])

  # Coming-soon tabs have no backing state, so their key handling returns
  # {:noreply, state, render?: false}; unwrap either arity to the new state.
  defp noreply_state({:noreply, state}), do: state
  defp noreply_state({:noreply, state, _opts}), do: state

  defp multi(mode) do
    %MultiScreenState{
      active_mode: mode,
      chat_state: State.new(nil, ExRatatui.textarea_new()),
      dashboard_state: TuiSystem.new(:agent)
    }
  end

  for mode <- [:dashboard, :research, :mesh] do
    test "Ctrl+C on the #{mode} tab arms exit, then quits" do
      armed = noreply_state(TUI.handle_event(ctrl_c(), multi(unquote(mode))))
      assert armed.chat_state.ctrl_c_pending == :exit

      assert {:stop, _state} = TUI.handle_event(ctrl_c(), armed)
    end

    test "a non-Ctrl+C key disarms the pending quit on the #{mode} tab" do
      armed = noreply_state(TUI.handle_event(ctrl_c(), multi(unquote(mode))))
      assert armed.chat_state.ctrl_c_pending == :exit

      disarmed = noreply_state(TUI.handle_event(key("x"), armed))
      assert disarmed.chat_state.ctrl_c_pending == false
    end
  end

  test "arming Ctrl+C on the dashboard surfaces the hint in its status bar" do
    armed = noreply_state(TUI.handle_event(ctrl_c(), multi(:dashboard)))

    rendered =
      armed
      |> Shell.render(%Frame{width: 120, height: 40})
      |> Enum.flat_map(fn
        {%{text: text}, _rect} when is_list(text) -> text
        _ -> []
      end)
      |> Enum.flat_map(& &1.spans)
      |> Enum.map_join(" ", & &1.content)

    assert rendered =~ "Press Ctrl+C again to exit"
  end

  test "chat keeps its own Ctrl+C behavior (arm then quit)" do
    {:noreply, armed} = TUI.handle_event(ctrl_c(), multi(:chat))
    assert armed.chat_state.ctrl_c_pending == :exit

    assert {:stop, _state} = TUI.handle_event(ctrl_c(), armed)
  end
end
