defmodule Beamcore.TUI.StateComponentsTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Events
  alias Beamcore.TUI.Components.Help
  alias Beamcore.TUI.Components.System
  alias Beamcore.TUI.State

  test "internal event buffer keeps compact recent execution notices" do
    state = %State{activity: []}

    state =
      Enum.reduce(1..260, state, fn n, current ->
        State.add_activity(current, "eeva", %{"code" => "step = #{n}"}, :done)
      end)

    assert length(state.activity) == 260
    assert hd(state.activity).label =~ "step = 260"
  end

  test "internal execution notice remains compact" do
    state = %State{activity: []}
    state = State.add_activity(state, "eeva", %{"code" => "File.read!(\"README.md\")"}, :done)
    assert hd(state.activity).label =~ "eeva"
    assert hd(state.activity).summary =~ "File.read!"
  end

  test "rate-limit execution notice stays recoverable and non-error status" do
    state = %State{activity: [], messages: [], status: :thinking}

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
    state = %State{activity: [], messages: [], status: :thinking}

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

  test "help popup documents memory commands" do
    widget = Help.widget()
    assert widget.content.text =~ "/memory list"
    assert widget.content.text =~ "/memory search"
    assert widget.content.text =~ "/memory forget"
    assert widget.content.text =~ "/memory clear"
  end

  test "system screen shows effective Eeva limits" do
    text =
      System.new(:agent)
      |> System.render_text(100, 80)
      |> Enum.flat_map(& &1.spans)
      |> Enum.map_join(& &1.content)

    assert text =~ "Eeva Limits"
    assert text =~ "timeout"
    assert text =~ "180s"
    assert text =~ "memory"
    assert text =~ "256MiB"
    assert text =~ "reductions"
    assert text =~ "40M"
    assert text =~ "output"
    assert text =~ "250KiB"
    assert text =~ "result"
    assert text =~ "125KiB"
  end

  test "Eeva limits expose runtime config overrides" do
    previous = Beamcore.Config.get(:eeva_timeout_ms)
    Beamcore.Config.put(:eeva_timeout_ms, "1234")

    try do
      assert Beamcore.Agent.Tools.Eeva.limits().timeout_ms == 1234
    after
      case previous do
        nil -> Beamcore.Config.delete(:eeva_timeout_ms)
        value -> Beamcore.Config.put(:eeva_timeout_ms, value)
      end
    end
  end
end
