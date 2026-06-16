defmodule Beamcore.TUI do
  @moduledoc """
  Primary terminal UI for the agent chat, implemented as a supervised ExRatatui.App.
  """

  use ExRatatui.App

  alias Beamcore.TUI.{Events, FileFinder, Layout, MultiScreenState, Render, State}
  alias ExRatatui.Layout.Rect

  require Logger

  # :none is a valid logger level at runtime (Elixir 1.19+) but not yet in the
  # typespec. Suppress the false positive until upstream updates the spec.
  @dialyzer {:nowarn_function, [start: 0, start: 1]}

  @animated_statuses [:thinking, :tool_running, :local_search, :rate_limited]

  def start(opts \\ []) do
    old_level = Logger.level()
    Logger.configure(level: :none)
    opts = Keyword.put_new(opts, :mouse_capture, true)

    try do
      if Process.whereis(Beamcore.TUI.DynamicSupervisor) do
        case DynamicSupervisor.start_child(Beamcore.TUI.DynamicSupervisor, {__MODULE__, opts}) do
          {:ok, pid} -> wait_for_termination(pid)
          {:error, {:already_started, _pid}} -> {:error, :already_running}
        end
      else
        case start_link(opts) do
          {:ok, pid} -> wait_for_termination(pid)
          other -> other
        end
      end
    rescue
      error ->
        Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :tui_start)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :tui_start)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Logger.configure(level: old_level)
    end
  end

  defp wait_for_termination(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        if reason not in [:normal, :shutdown] do
          Beamcore.AppLog.error("TUI process stopped unexpectedly", reason: inspect(reason))
        end

        :ok
    end
  end

  @impl true
  def mount(opts) do
    :timer.send_interval(100, self(), :tick)

    parent = self()

    Task.start(fn ->
      files = FileFinder.load_files()
      send(parent, {:file_finder_cache, files})
    end)

    f1_state = State.new(nil, ExRatatui.textarea_new(), Keyword.put(opts, :screen_type, :agent))
    f2_state = State.new(nil, ExRatatui.textarea_new(), Keyword.put(opts, :screen_type, :chat))

    state = %MultiScreenState{
      active_screen: :f1,
      f1_state: f1_state,
      f2_state: f2_state
    }

    {:ok, init_viewports(state)}
  end

  defp init_viewports(state) do
    {width, height} = ExRatatui.terminal_size()
    set_viewports(state, width, height)
  end

  defp set_viewports(state, width, height) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    %{
      state
      | f1_state:
          State.set_chat_viewport_height(
            state.f1_state,
            Layout.chat_viewport_height(area, state.f1_state.screen_type)
          ),
        f2_state:
          State.set_chat_viewport_height(
            state.f2_state,
            Layout.chat_viewport_height(area, state.f2_state.screen_type)
          )
    }
  end

  @impl true
  def render(state, frame) do
    try do
      state
      |> MultiScreenState.get_active()
      |> Render.render(frame)
    rescue
      error ->
        Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :tui_render)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :tui_render)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @impl true
  def handle_event(event, state) do
    try do
      case event do
        %ExRatatui.Event.Key{code: "f1"} ->
          switch_or_delegate(event, state, :f1)

        %ExRatatui.Event.Key{code: "f2"} ->
          switch_or_delegate(event, state, :f2)

        %ExRatatui.Event.Resize{width: width, height: height} ->
          new_state =
            state
            |> set_viewports(width, height)
            |> MultiScreenState.update_active(&State.mark_dirty/1)

          {:noreply, new_state}

        _ ->
          delegate_event(event, state, state.active_screen)
      end
    rescue
      error ->
        Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :tui_event)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :tui_event)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp switch_or_delegate(event, state, screen) do
    if state.active_screen == screen do
      delegate_event(event, state, screen)
    else
      new_state = %{state | active_screen: screen}
      new_state = MultiScreenState.update_active(new_state, &State.mark_dirty/1)
      {:noreply, new_state}
    end
  end

  defp delegate_event(event, state, screen) do
    screen_state = screen_state(state, screen)

    case Events.handle_event(event, screen_state) do
      {:stop, new_screen_state} ->
        {:stop, put_screen_state(state, screen, new_screen_state)}

      {:noreply, new_screen_state} ->
        new_state = put_screen_state(state, screen, new_screen_state)

        if new_screen_state.status == :quit,
          do: {:stop, new_state},
          else: {:noreply, new_state}
    end
  end

  defp screen_state(state, :f1), do: state.f1_state
  defp screen_state(state, :f2), do: state.f2_state

  defp put_screen_state(state, :f1, f1_state), do: %{state | f1_state: f1_state}
  defp put_screen_state(state, :f2, f2_state), do: %{state | f2_state: f2_state}

  defp animating?(%{status: status}), do: status in @animated_statuses
  defp animating?(_state), do: false

  @impl true
  def handle_info(:tick, state) do
    if animating?(MultiScreenState.get_active(state)) do
      now = System.monotonic_time(:millisecond)

      {:noreply,
       %{
         state
         | f1_state: State.tick(state.f1_state, now),
           f2_state: State.tick(state.f2_state, now)
       }}
    else
      {:noreply, state, render?: false}
    end
  end

  @impl true
  def handle_info({:runtime_event, worker_pid, event}, state) do
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

        Logger.warning("TUI dropping runtime event from unknown worker #{inspect(worker_pid)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:agent_done, worker_pid, session}, state) do
    cond do
      state.f1_state.worker == worker_pid ->
        {:noreply, %{state | f1_state: Events.finish_worker(state.f1_state, session)}}

      state.f2_state.worker == worker_pid ->
        {:noreply, %{state | f2_state: Events.finish_worker(state.f2_state, session)}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:agent_error, worker_pid, error, stacktrace}, state) do
    Beamcore.AppLog.exception(:error, error, stacktrace, boundary: :agent_worker)
    formatted_error = Exception.format(:error, error, stacktrace)
    user_error = Beamcore.AppLog.user_message()

    cond do
      state.f1_state.worker == worker_pid ->
        {:noreply, %{state | f1_state: Events.fail_worker(state.f1_state, user_error)}}

      state.f2_state.worker == worker_pid ->
        {:noreply, %{state | f2_state: Events.fail_worker(state.f2_state, user_error)}}

      true ->
        Beamcore.AppLog.warn("TUI received error from unknown worker", error: formatted_error)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_finder_cache, files}, state) do
    set_cache = fn screen_state ->
      %{screen_state | file_finder_cache: screen_state.file_finder_cache || files}
    end

    {:noreply,
     %{
       state
       | f1_state: set_cache.(state.f1_state),
         f2_state: set_cache.(state.f2_state)
     }}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
