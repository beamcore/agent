defmodule Beamcore.TUI do
  @moduledoc """
  Primary terminal UI for the agent chat, implemented as a supervised ExRatatui.App.
  """

  use ExRatatui.App

  alias Beamcore.TUI.{FileFinder, Layout, MessageRouter, MultiScreenState, Render, State}
  alias ExRatatui.Layout.Rect

  require Logger

  @dialyzer {:nowarn_function, [start: 0, start: 1]}

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
          MessageRouter.switch_or_delegate(event, state, :f1)

        %ExRatatui.Event.Key{code: "f2"} ->
          MessageRouter.switch_or_delegate(event, state, :f2)

        %ExRatatui.Event.Resize{width: width, height: height} ->
          new_state =
            state
            |> set_viewports(width, height)
            |> MultiScreenState.update_active(&State.mark_dirty/1)

          {:noreply, new_state}

        _ ->
          MessageRouter.delegate_event(event, state, state.active_screen)
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

  @impl true
  def handle_info(:tick, state), do: MessageRouter.route_tick(state)

  @impl true
  def handle_info({:runtime_event, worker_pid, event}, state),
    do: MessageRouter.route_runtime_event(worker_pid, event, state)

  @impl true
  def handle_info({:agent_done, worker_pid, session}, state),
    do: MessageRouter.route_agent_done(worker_pid, session, state)

  @impl true
  def handle_info({:agent_error, worker_pid, error, stacktrace}, state),
    do: MessageRouter.route_agent_error(worker_pid, error, stacktrace, state)

  @impl true
  def handle_info({:file_finder_cache, files}, state),
    do: MessageRouter.route_file_finder_cache(files, state)

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
