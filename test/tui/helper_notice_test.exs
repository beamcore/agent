defmodule Beamcore.TUI.HelperNoticeTest do
  use ExUnit.Case

  alias Beamcore.TUI.{Events, State}

  test "helper progress is transient status and does not pollute chat messages" do
    state = %State{messages: [], notice: nil}
    state = Events.handle_runtime_event({:local_info, "Checking helper..."}, state)

    assert state.notice == "Checking helper..."
    assert state.messages == []

    state = Events.handle_runtime_event({:assistant, "Done"}, state)
    assert state.notice == nil
    assert [%{role: :assistant, content: "Done"}] = state.messages
  end
end
