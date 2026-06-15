defmodule Beamcore.TUI.StateComponentsTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Events
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

  test "rate-limit execution notice stays recoverable and non-error status" do
    state = %State{activity: [], messages: [], activity_follow_tail?: true, status: :thinking}

    state =
      Events.handle_runtime_event(
        {:execution_stopped,
         %{
           source: :provider,
           reason: :rate_limited,
           summary: "Provider rate limit reached. Retrying automatically in 5ms.",
           details: %{retry_after_ms: 5},
           recoverable?: true
         }},
        state
      )

    assert state.status == :rate_limited
    assert [%{role: :system, content: content}] = state.messages
    assert content =~ "Retrying automatically"
  end

  test "retry wait event creates UI-only countdown state" do
    state = %State{activity: [], messages: [], activity_follow_tail?: true, status: :thinking}

    state =
      Events.handle_runtime_event(
        {:retry_wait,
         %{
           reason: :rate_limit,
           wait_ms: 12_000,
           now_ms: 1_000,
           message: "Rate limit reached. Retrying automatically in 12s."
         }},
        state
      )

    assert state.status == :rate_limited
    assert State.wait_status_text(state, 1_000) == "Rate limited · retrying in 12s"
    assert State.wait_status_text(state, 2_200) == "Rate limited · retrying in 11s"
    assert state.messages == []
  end

  test "retry countdown ticks do not append chat history" do
    state =
      %State{messages: [%{role: :system, content: "waiting"}], status: :rate_limited}
      |> State.set_wait_status(%{reason: :backoff, wait_ms: 3_000, now_ms: 0})

    ticked = State.tick(state, 1_000)

    assert ticked.messages == state.messages
    assert State.wait_status_text(ticked, 1_000) == "Waiting for provider · retrying in 2s"
  end

  test "retry countdown clears when provider resumes or worker finishes" do
    state =
      %State{status: :thinking}
      |> State.set_wait_status(%{reason: :rate_limit, wait_ms: 5_000, now_ms: 0})

    assert state.wait_status

    resumed = Events.handle_runtime_event({:retry_resumed, %{reason: :rate_limit}}, state)
    assert resumed.wait_status == nil

    thinking = Events.handle_runtime_event({:status, :thinking}, state)
    assert thinking.wait_status == nil
  end

  test "recoverable execution errors show session continuity without ending input state" do
    state = %State{activity: [], messages: [], activity_follow_tail?: true, status: :thinking}

    state =
      Events.handle_runtime_event(
        {:execution_stopped,
         %{
           source: :eeva,
           reason: :execution_failed,
           summary: "Eeva stopped: boom",
           details: %{},
           recoverable?: true
         }},
        state
      )

    assert state.status == :error
    assert state.worker == nil
    assert [%{role: :error, content: content}] = state.messages
    assert content =~ "Eeva stopped: boom"
    assert content =~ "Session is still active"
    assert content =~ "Ask the agent to retry."
  end

  test "worker crash message points to app log and keeps TUI idle" do
    state =
      %State{messages: [], status: :thinking, worker: self(), ctrl_c_pending: :pause}
      |> State.set_wait_status(%{reason: :backoff, wait_ms: 2_000, now_ms: 0})

    state = Events.fail_worker(state, "boom")

    assert state.status == :idle
    assert state.worker == nil
    assert state.ctrl_c_pending == false
    assert state.wait_status == nil
    assert [%{role: :error, content: content}] = state.messages
    assert content =~ "Agent worker crashed"
    assert content =~ Beamcore.AppLog.log_path()
    assert content =~ "Session is still active"
  end
end
