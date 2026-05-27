defmodule Beamcore.TUI do
  @moduledoc """
  Primary terminal UI for the agent chat, implemented as a supervised ExRatatui.App.
  """

  use ExRatatui.App

  alias Beamcore.TUI.{Events, Render, State}

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
    # Enable native terminal mouse scroll and click capture
    IO.write("\e[?1000h\e[?1002h\e[?1006h")

    # Start periodic ticking for animations (e.g. spinners, mascot)
    :timer.send_interval(100, self(), :tick)

    # Initialize presentational state
    state = State.new(nil, ExRatatui.textarea_new(), opts)

    # Automatically trigger drawing on initial mount
    {:ok, state}
  end

  @impl true
  def render(state, frame) do
    Render.render(state, frame)
  end

  @impl true
  def handle_event(event, state) do
    case Events.handle_event(event, state) do
      {:stop, new_state} ->
        {:stop, new_state}

      {:noreply, new_state} ->
        if new_state.status == :quit do
          {:stop, new_state}
        else
          {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    {:noreply, State.tick(state, now)}
  end

  @impl true
  def handle_info({:runtime_event, event}, state) do
    new_state = Events.handle_runtime_event(event, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:agent_done, _pid, session}, state) do
    new_state = Events.finish_worker(state, session)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Restore terminal mouse settings on exit
    IO.write("\e[?1000l\e[?1002l\e[?1006l")
    :ok
  end
end
