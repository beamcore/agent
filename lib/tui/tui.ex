defmodule Beamcore.TUI do
  @moduledoc """
  Primary terminal UI for the agent chat, implemented as a supervised ExRatatui.App.
  """

  use ExRatatui.App

  alias Beamcore.TUI.{FileFinder, Layout, MessageRouter, MultiScreenState, Render, State}
  alias Beamcore.TUI.Events.KeyEvents
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
    Task.start(fn -> send(parent, {:file_finder_cache, FileFinder.load_files()}) end)

    init_screen_providers()

    f1_state = State.new(nil, ExRatatui.textarea_new(), Keyword.put(opts, :screen_type, :agent))
    f2_state = State.new(nil, ExRatatui.textarea_new(), Keyword.put(opts, :screen_type, :chat))

    f3_state = Beamcore.TUI.Components.System.new(:agent)

    state = %MultiScreenState{
      active_screen: :f1,
      f1_state: f1_state,
      f2_state: f2_state,
      f3_state: f3_state
    }

    {:ok, set_viewports(state)}
  end

  defp set_viewports(state) do
    {w, h} = ExRatatui.terminal_size()
    set_viewports(state, w, h)
  end

  defp set_viewports(state, width, height) do
    area = %Rect{x: 0, y: 0, width: width, height: height}
    h1 = Layout.chat_viewport_height(area, state.f1_state.screen_type)
    h2 = Layout.chat_viewport_height(area, state.f2_state.screen_type)

    %{
      state
      | f1_state: State.set_chat_viewport_height(state.f1_state, h1),
        f2_state: State.set_chat_viewport_height(state.f2_state, h2)
    }
  end

  @impl true
  def render(state, frame) do
    try do
      state |> MultiScreenState.get_active() |> Render.render(frame)
    rescue
      e -> render_error(frame, "Render error: #{Exception.message(e)}")
    catch
      k, r -> render_error(frame, "Render crash: #{inspect(k)} #{inspect(r)}")
    end
  end

  defp render_error(frame, text) do
    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    p = %ExRatatui.Widgets.Paragraph{
      text: text,
      style: Beamcore.TUI.Theme.style(:error),
      alignment: :center,
      wrap: true
    }

    [{p, area}]
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{} = event, state) do
    if KeyEvents.actionable?(event) do
      handle_actionable_event(event, state)
    else
      {:noreply, state, render?: false}
    end
  end

  @impl true
  def handle_event(event, state) do
    handle_actionable_event(event, state)
  end

  defp handle_actionable_event(event, state) do
    try do
      case event do
        %ExRatatui.Event.Key{code: "f1"} ->
          MessageRouter.switch_or_delegate(event, state, :f1)

        %ExRatatui.Event.Key{code: "f2"} ->
          MessageRouter.switch_or_delegate(event, state, :f2)

        %ExRatatui.Event.Key{code: "f3"} ->
          try do
            {:noreply, switch_to_f3(state)}
          rescue
            e ->
              {:noreply, State.set_notice(state, "F3 error: #{Exception.message(e)}")}
          end

        %ExRatatui.Event.Resize{width: w, height: h} ->
          {:noreply,
           state |> set_viewports(w, h) |> MultiScreenState.update_active(&mark_active_dirty/1)}

        _ ->
          MessageRouter.delegate_event(event, state, state.active_screen)
      end
    rescue
      e ->
        Beamcore.AppLog.exception(:error, e, __STACKTRACE__, boundary: :tui_event)
        reraise e, __STACKTRACE__
    catch
      k, r ->
        Beamcore.AppLog.exception(k, r, __STACKTRACE__, boundary: :tui_event)
        :erlang.raise(k, r, __STACKTRACE__)
    end
  end

  @impl true
  def handle_info(msg, state), do: route_info(msg, state)

  defp route_info({:refresh_session, screen_type}, state) do
    screen = if screen_type == :chat, do: :f2, else: :f1
    old = MessageRouter.screen_state(state, screen)
    new_session = Beamcore.Agent.Chat.Session.new(nil, screen_type: screen_type)
    new_screen = %{old | session: new_session, messages: []} |> State.mark_dirty()
    {:noreply, MessageRouter.put_screen_state(state, screen, new_screen)}
  end

  defp route_info(:tick, state), do: MessageRouter.route_tick(state)

  defp route_info({:runtime_event, pid, event}, state),
    do: MessageRouter.route_runtime_event(pid, event, state)

  defp route_info({:agent_done, pid, session}, state),
    do: MessageRouter.route_agent_done(pid, session, state)

  defp route_info({:agent_error, pid, error, st}, state),
    do: MessageRouter.route_agent_error(pid, error, st, state)

  defp route_info({:file_finder_cache, files}, state),
    do: MessageRouter.route_file_finder_cache(files, state)

  defp route_info({:system_mesh_snapshot, ref, snapshot}, state),
    do: MessageRouter.route_system_mesh_snapshot(ref, snapshot, state)

  defp route_info({:provider_saved, ref, result}, state),
    do: MessageRouter.route_provider_saved(ref, result, state)

  defp route_info(_msg, state), do: {:noreply, state}

  defp switch_to_f3(state) do
    for = if state.active_screen == :f2, do: :chat, else: :agent

    f3 =
      if state.f3_state && state.f3_state.configure_for == for,
        do: state.f3_state,
        else: Beamcore.TUI.Components.System.new(for)

    %{state | active_screen: :f3, f3_state: f3}
  end

  defp mark_active_dirty(%{render_dirty?: _} = screen), do: State.mark_dirty(screen)
  defp mark_active_dirty(screen), do: screen

  defp init_screen_providers do
    case Beamcore.Config.active_provider() do
      nil ->
        :ok

      global ->
        for screen <- [:agent, :chat],
            Beamcore.Config.get(:"active_provider_#{screen}") == nil,
            do: Beamcore.Config.set_active_provider(screen, global)
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
