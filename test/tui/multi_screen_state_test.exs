defmodule Beamcore.TUI.MultiScreenStateTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.{MultiScreenState, State}

  defp multi(active_mode) do
    %MultiScreenState{
      active_mode: active_mode,
      chat_state: State.new(nil, ExRatatui.textarea_new()),
      dashboard_state: TuiSystem.new(:agent)
    }
  end

  test "get_active returns the chat state in chat mode" do
    state = multi(:chat)
    assert MultiScreenState.get_active(state) == state.chat_state
  end

  test "get_active returns the dashboard state in dashboard mode" do
    state = multi(:dashboard)
    assert MultiScreenState.get_active(state) == state.dashboard_state
  end

  test "get_active returns nil for a coming-soon mode" do
    assert MultiScreenState.get_active(multi(:research)) == nil
  end

  test "put_active writes back to the active mode's slot" do
    state = multi(:chat)
    updated = MultiScreenState.put_active(state, %{state.chat_state | scroll_offset: 7})
    assert updated.chat_state.scroll_offset == 7
  end

  test "put_active is a no-op for a coming-soon mode" do
    state = multi(:research)
    assert MultiScreenState.put_active(state, :anything) == state
  end

  test "update_active maps the active state, and is a no-op when there is none" do
    state = multi(:chat)
    updated = MultiScreenState.update_active(state, &%{&1 | scroll_offset: 3})
    assert updated.chat_state.scroll_offset == 3

    placeholder = multi(:research)
    assert MultiScreenState.update_active(placeholder, fn _ -> :boom end) == placeholder
  end
end
