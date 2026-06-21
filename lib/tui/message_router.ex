defmodule Beamcore.TUI.MessageRouter do
  @moduledoc false

  alias Beamcore.TUI.{Events, MultiScreenState, State}

  @animated_statuses [:thinking, :tool_running, :local_search, :rate_limited]

  def switch_or_delegate(event, state, screen) do
    if state.active_screen == screen do
      delegate_event(event, state, screen)
    else
      new_state = %{state | active_screen: screen}
      new_state = MultiScreenState.update_active(new_state, &mark_dirty/1)
      {:noreply, new_state}
    end
  end

  defdelegate delegate_event(event, state, screen), to: __MODULE__.Delegate, as: :call

  def screen_state(state, :f1), do: state.f1_state
  def screen_state(state, :f2), do: state.f2_state
  def screen_state(state, :f3), do: state.f3_state

  def put_screen_state(state, :f1, s), do: %{state | f1_state: s}
  def put_screen_state(state, :f2, s), do: %{state | f2_state: s}
  def put_screen_state(state, :f3, s), do: %{state | f3_state: s}

  def animating?(%{status: status}), do: status in @animated_statuses
  def animating?(_state), do: false

  def route_tick(state) do
    if animating?(MultiScreenState.get_active(state)) do
      now = System.monotonic_time(:millisecond)

      {:noreply,
       %{
         state
         | f1_state: State.tick(state.f1_state, now),
           f2_state: State.tick(state.f2_state, now)
       }}
    else
      # F3 mesh fetches live data at render time, so keep re-rendering when active
      if state.active_screen == :f3,
        do: {:noreply, state},
        else: {:noreply, state, render?: false}
    end
  end

  def route_runtime_event(worker_pid, event, state) do
    cond do
      worker_pid == self() ->
        active_screen = state.active_screen
        active_state = MultiScreenState.get_active(state)
        new_active = Events.handle_runtime_event(event, active_state)
        {:noreply, put_screen_state(state, active_screen, new_active)}

      state.f1_state.worker == worker_pid ->
        {:noreply, %{state | f1_state: Events.handle_runtime_event(event, state.f1_state)}}

      state.f2_state.worker == worker_pid ->
        {:noreply, %{state | f2_state: Events.handle_runtime_event(event, state.f2_state)}}

      true ->
        Beamcore.AppLog.warn("TUI dropped runtime event from unknown worker",
          worker_pid: inspect(worker_pid)
        )

        {:noreply, state}
    end
  end

  def route_agent_done(worker_pid, session, state) do
    cond do
      state.f1_state.worker == worker_pid ->
        {:noreply, %{state | f1_state: Events.finish_worker(state.f1_state, session)}}

      state.f2_state.worker == worker_pid ->
        {:noreply, %{state | f2_state: Events.finish_worker(state.f2_state, session)}}

      true ->
        {:noreply, state}
    end
  end

  def route_agent_error(worker_pid, error, stacktrace, state) do
    Beamcore.AppLog.exception(:error, error, stacktrace, boundary: :agent_worker)
    user_error = Beamcore.AppLog.user_message()

    cond do
      state.f1_state.worker == worker_pid ->
        {:noreply, %{state | f1_state: Events.fail_worker(state.f1_state, user_error)}}

      state.f2_state.worker == worker_pid ->
        {:noreply, %{state | f2_state: Events.fail_worker(state.f2_state, user_error)}}

      true ->
        formatted = Exception.format(:error, error, stacktrace)
        Beamcore.AppLog.warn("TUI received error from unknown worker", error: formatted)
        {:noreply, state}
    end
  end

  def route_file_finder_cache(files, state) do
    set_cache = fn s -> %{s | file_finder_cache: s.file_finder_cache || files} end

    {:noreply,
     %{state | f1_state: set_cache.(state.f1_state), f2_state: set_cache.(state.f2_state)}}
  end

  defp mark_dirty(%{render_dirty?: _} = s), do: State.mark_dirty(s)
  defp mark_dirty(s), do: s
end
