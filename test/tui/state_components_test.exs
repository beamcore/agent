defmodule Beamcore.TUI.StateComponentsTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.State
  alias Beamcore.TUI.Components.Activity

  test "activity keeps a long visible history instead of only a few actions" do
    state = %State{activity: [], activity_follow_tail?: true}

    state =
      Enum.reduce(1..260, state, fn n, current ->
        State.add_activity(current, "eeva", %{"code" => "step = #{n}"}, :done)
      end)

    assert length(state.activity) == 260
    assert hd(state.activity).label =~ "step = 260"
  end

  test "visible activity remains viewport sliced" do
    state = %State{activity: [], activity_follow_tail?: true}

    state =
      Enum.reduce(1..100, state, fn n, current ->
        State.add_activity(current, "eeva", %{"code" => "step = #{n}"}, :done)
      end)

    assert length(State.visible_timeline_items(state, 12)) <= 16
  end

  test "activity renders eeva executions" do
    state = %State{activity: [], activity_follow_tail?: true}
    state = State.add_activity(state, "eeva", %{"code" => "File.read!(\"README.md\")"}, :done)
    assert Activity.compact_text(state) =~ "eeva"
  end
end
