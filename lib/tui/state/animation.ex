defmodule Beamcore.TUI.State.Animation do
  @moduledoc false

  def tick(state, now_ms) do
    %{state | spinner_step: state.spinner_step + 1, last_animation_tick_ms: now_ms}
  end

  def animation_due?(%{last_animation_tick_ms: 0} = _state, now_ms) when now_ms < 0, do: true

  def animation_due?(state, now_ms) do
    now_ms - state.last_animation_tick_ms >= animation_interval(state)
  end

  def animation_interval(%{status: status, messages: messages}) do
    cond do
      status in [:thinking, :tool_running, :local_search, :rate_limited] -> 160
      messages == [] -> 360
      true -> 420
    end
  end

  def poll_timeout_ms(state, now_ms) do
    elapsed = animation_elapsed_ms(state, now_ms)
    until_animation = max(animation_interval(state) - elapsed, 0)

    cond do
      state.status in [:thinking, :tool_running, :local_search, :rate_limited] ->
        clamp_poll(until_animation, 18, 42)

      state.show_commands ->
        24

      state.worker != nil ->
        clamp_poll(until_animation, 24, 48)

      true ->
        clamp_poll(until_animation, 10, 16)
    end
  end

  defp animation_elapsed_ms(%{last_animation_tick_ms: 0}, now_ms) when now_ms < 0,
    do: animation_interval(%{status: :thinking, messages: []})

  defp animation_elapsed_ms(state, now_ms),
    do: max(now_ms - state.last_animation_tick_ms, 0)

  defp clamp_poll(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end
end
