defmodule Beamcore.TUI.MessageRouter do
  @moduledoc false

  alias Beamcore.TUI.{Events, FileFinder, MultiScreenState, State}
  alias Beamcore.TUI.Components.System, as: TuiSystem

  @animated_statuses [:thinking, :tool_running, :local_search, :rate_limited]

  def switch_or_delegate(event, state, mode) do
    cond do
      state.active_mode != mode ->
        switched =
          %{state | active_mode: mode}
          |> MultiScreenState.update_active(&mark_dirty/1)

        {:noreply, switched}

      MultiScreenState.get_active(state) == nil ->
        {:noreply, state, render?: false}

      true ->
        delegate_event(event, state, mode)
    end
  end

  defdelegate delegate_event(event, state, mode), to: __MODULE__.Delegate, as: :call

  def screen_state(state, :chat), do: state.chat_state
  def screen_state(state, :dashboard), do: state.dashboard_state

  def put_screen_state(state, :chat, s), do: %{state | chat_state: s}
  def put_screen_state(state, :dashboard, s), do: %{state | dashboard_state: s}

  def animating?(%{status: status}), do: status in @animated_statuses
  def animating?(_state), do: false

  def route_tick(state) do
    cond do
      animating?(MultiScreenState.get_active(state)) ->
        now = System.monotonic_time(:millisecond)
        {:noreply, %{state | chat_state: State.tick(state.chat_state, now)}}

      state.active_mode == :dashboard ->
        dashboard =
          %{state.dashboard_state | activity: dashboard_activity(state.chat_state)}
          |> TuiSystem.maybe_refresh_mesh()
          |> TuiSystem.clamp_activity_offset()

        {:noreply, %{state | dashboard_state: dashboard}}

      true ->
        {:noreply, state, render?: false}
    end
  end

  def route_system_mesh_snapshot(ref, snapshot, state) do
    {:noreply,
     %{
       state
       | dashboard_state: TuiSystem.finish_mesh_refresh(state.dashboard_state, ref, snapshot)
     }}
  end

  def route_provider_saved(ref, result, state) do
    {:noreply,
     %{
       state
       | dashboard_state: TuiSystem.finish_provider_save(state.dashboard_state, ref, result)
     }}
  end

  def route_provider_action_done(ref, action, result, state) do
    {:noreply,
     %{
       state
       | dashboard_state:
           TuiSystem.finish_provider_action(state.dashboard_state, ref, action, result)
     }}
  end

  def route_runtime_event(worker_pid, event, state) do
    cond do
      worker_pid == self() ->
        case MultiScreenState.get_active(state) do
          nil ->
            {:noreply, state}

          active ->
            {:noreply,
             MultiScreenState.put_active(state, Events.handle_runtime_event(event, active))}
        end

      state.chat_state.worker == worker_pid ->
        {:noreply, %{state | chat_state: Events.handle_runtime_event(event, state.chat_state)}}

      true ->
        Beamcore.AppLog.warn("TUI dropped runtime event from unknown worker",
          worker_pid: inspect(worker_pid)
        )

        {:noreply, state}
    end
  end

  def route_agent_done(worker_pid, session, state) do
    if state.chat_state.worker == worker_pid do
      {:noreply, %{state | chat_state: Events.finish_worker(state.chat_state, session)}}
    else
      {:noreply, state}
    end
  end

  def route_agent_error(worker_pid, error, stacktrace, state) do
    Beamcore.AppLog.exception(:error, error, stacktrace, boundary: :agent_worker)
    user_error = Beamcore.AppLog.user_message()

    if state.chat_state.worker == worker_pid do
      {:noreply, %{state | chat_state: Events.fail_worker(state.chat_state, user_error)}}
    else
      formatted = Exception.format(:error, error, stacktrace)
      Beamcore.AppLog.warn("TUI received error from unknown worker", error: formatted)
      {:noreply, state}
    end
  end

  def route_file_finder_cache(files, state) do
    active_before? = state.chat_state.file_finder_active?

    set_cache = fn s ->
      cache = s.file_finder_cache || files

      s = %{s | file_finder_cache: cache, file_finder_loading?: false}

      if s.file_finder_active? do
        State.update_file_finder_query(
          s,
          s.file_finder_query,
          FileFinder.search(s.file_finder_query, cache)
        )
      else
        s
      end
    end

    updated = %{state | chat_state: set_cache.(state.chat_state)}

    if active_before? do
      {:noreply, updated}
    else
      {:noreply, updated, render?: false}
    end
  end

  defp dashboard_activity(%{activity: activity}) when is_list(activity), do: activity
  defp dashboard_activity(_chat_state), do: []

  defp mark_dirty(%{render_dirty?: _} = s), do: State.mark_dirty(s)
  defp mark_dirty(s), do: s
end
