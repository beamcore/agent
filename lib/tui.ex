defmodule Beamcore.TUI do
  @moduledoc """
  Primary terminal UI for the agent chat, implemented as a supervised ExRatatui.App.
  """

  use ExRatatui.App

  alias Beamcore.TUI.{Events, MultiScreenState, Render, State}

  # --- Client API ---

  @doc """
  Launches the supervised TUI process and blocks the calling thread,
  monitoring it until the TUI exits.
  """
  def start(opts \\ []) do
    if Process.whereis(Beamcore.TUI.DynamicSupervisor) do
      case DynamicSupervisor.start_child(Beamcore.TUI.DynamicSupervisor, {__MODULE__, opts}) do
        {:ok, pid} ->
          wait_for_termination(pid)

        {:error, {:already_started, _pid}} ->
          {:error, :already_running}
      end
    else
      # Standalone/fallback/test execution
      case start_link(opts) do
        {:ok, pid} ->
          wait_for_termination(pid)

        other ->
          other
      end
    end
  end

  defp wait_for_termination(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    end
  end

  # --- ExRatatui.App Callbacks ---

  @impl true
  def mount(opts) do
    # Start periodic ticking for animations (e.g. spinners, mascot)
    :timer.send_interval(100, self(), :tick)

    # Initialize presentational states for all three screens
    f1_state = State.new(nil, ExRatatui.textarea_new(), opts |> Keyword.put(:screen_type, :agent))
    f2_state = State.new(nil, ExRatatui.textarea_new(), opts |> Keyword.put(:screen_type, :chat))
    f3_state = State.new(nil, ExRatatui.textarea_new(), opts |> Keyword.put(:screen_type, :research))

    state = %MultiScreenState{
      active_screen: :f1,
      f1_state: f1_state,
      f2_state: f2_state,
      f3_state: f3_state
    }

    {:ok, state}
  end

  @impl true
  def render(state, frame) do
    active_state = MultiScreenState.get_active(state)
    Render.render(active_state, frame)
  end

  @impl true
  def handle_event(event, state) do
    case event do
      %ExRatatui.Event.Key{code: "f1"} ->
        if state.active_screen == :f1 do
          delegate_event(event, state, :f1)
        else
          new_state = %{state | active_screen: :f1}
          new_state = MultiScreenState.update_active(new_state, &State.mark_dirty/1)
          {:noreply, new_state}
        end

      %ExRatatui.Event.Key{code: "f2"} ->
        if state.active_screen == :f2 do
          delegate_event(event, state, :f2)
        else
          new_state = %{state | active_screen: :f2}
          new_state = MultiScreenState.update_active(new_state, &State.mark_dirty/1)
          {:noreply, new_state}
        end

      %ExRatatui.Event.Key{code: "f3"} ->
        if state.active_screen == :f3 do
          delegate_event(event, state, :f3)
        else
          new_state = %{state | active_screen: :f3}
          new_state = MultiScreenState.update_active(new_state, &State.mark_dirty/1)
          {:noreply, new_state}
        end

      _ ->
        delegate_event(event, state, state.active_screen)
    end
  end

  defp delegate_event(event, state, screen) do
    screen_state =
      case screen do
        :f1 -> state.f1_state
        :f2 -> state.f2_state
        :f3 -> state.f3_state
      end

    case Events.handle_event(event, screen_state) do
      {:stop, new_screen_state} ->
        new_state = put_screen_state(state, screen, new_screen_state)
        {:stop, new_state}

      {:noreply, new_screen_state} ->
        new_state = put_screen_state(state, screen, new_screen_state)
        if new_screen_state.status == :quit do
          {:stop, new_state}
        else
          {:noreply, new_state}
        end
    end
  end

  defp put_screen_state(state, :f1, f1_state), do: %{state | f1_state: f1_state}
  defp put_screen_state(state, :f2, f2_state), do: %{state | f2_state: f2_state}
  defp put_screen_state(state, :f3, f3_state), do: %{state | f3_state: f3_state}

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    new_state = %{state |
      f1_state: State.tick(state.f1_state, now),
      f2_state: State.tick(state.f2_state, now),
      f3_state: State.tick(state.f3_state, now)
    }
    {:noreply, new_state}
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
        new_f1 = Events.handle_runtime_event(event, state.f1_state)
        {:noreply, %{state | f1_state: new_f1}}

      state.f2_state.worker == worker_pid ->
        new_f2 = Events.handle_runtime_event(event, state.f2_state)
        {:noreply, %{state | f2_state: new_f2}}

      state.f3_state.worker == worker_pid ->
        new_f3 = Events.handle_runtime_event(event, state.f3_state)
        {:noreply, %{state | f3_state: new_f3}}

      true ->
        active_screen = state.active_screen
        active_state = MultiScreenState.get_active(state)
        new_active = Events.handle_runtime_event(event, active_state)
        {:noreply, put_screen_state(state, active_screen, new_active)}
    end
  end

  @impl true
  def handle_info({:agent_done, worker_pid, session}, state) do
    cond do
      state.f1_state.worker == worker_pid ->
        new_f1 = Events.finish_worker(state.f1_state, session)
        {:noreply, %{state | f1_state: new_f1}}

      state.f2_state.worker == worker_pid ->
        new_f2 = Events.finish_worker(state.f2_state, session)
        {:noreply, %{state | f2_state: new_f2}}

      state.f3_state.worker == worker_pid ->
        new_f3 = Events.finish_worker(state.f3_state, session)
        {:noreply, %{state | f3_state: new_f3}}

      true ->
        active_screen = state.active_screen
        active_state = MultiScreenState.get_active(state)
        new_active = Events.finish_worker(active_state, session)
        {:noreply, put_screen_state(state, active_screen, new_active)}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
