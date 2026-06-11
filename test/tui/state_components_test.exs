defmodule Beamcore.TUI.StateComponentsTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.State

  test "internal event buffer keeps compact recent execution notices" do
    state = %State{activity: [], activity_follow_tail?: true}

    state =
      Enum.reduce(1..260, state, fn n, current ->
        State.add_activity(current, "eeva", %{"code" => "step = #{n}"}, :done)
      end)

    assert length(state.activity) == 260
    assert hd(state.activity).label =~ "step = 260"
  end

  test "internal event slices remain bounded for status/debug uses" do
    state = %State{activity: [], activity_follow_tail?: true}

    state =
      Enum.reduce(1..100, state, fn n, current ->
        State.add_activity(current, "eeva", %{"code" => "step = #{n}"}, :done)
      end)

    assert length(State.visible_timeline_items(state, 12)) <= 16
  end

  test "internal execution notice remains compact" do
    state = %State{activity: [], activity_follow_tail?: true}
    state = State.add_activity(state, "eeva", %{"code" => "File.read!(\"README.md\")"}, :done)
    assert hd(state.activity).label =~ "eeva"
    assert hd(state.activity).summary =~ "File.read!"
  end
end
