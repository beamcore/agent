defmodule Beamcore.FileMutationQueue do
  @moduledoc """
  An in-memory lock manager/queue to serialize file mutations on a per-file basis,
  ensuring no race conditions between concurrent read-modify-write operations.
  """
  use GenServer
  require Logger

  # Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Runs the given function inside a lock for the specified file path.
  If the lock is held, waits/retries until it is released or times out.
  """
  def with_lock(path, timeout \\ 5000, fun) do
    case acquire_lock(path, timeout) do
      :ok ->
        try do
          fun.()
        after
          release_lock(path)
        end

      {:error, :timeout} ->
        {:error, :lock_timeout}
    end
  end

  @doc """
  Acquires a lock for the given path. Blocks the calling process until the lock
  is granted or the timeout is reached.
  """
  def acquire_lock(path, timeout) do
    try do
      GenServer.call(__MODULE__, {:acquire, path}, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(__MODULE__, {:cancel, path, self()})
        {:error, :timeout}
    end
  end

  @doc """
  Releases the lock for the given path.
  """
  def release_lock(path) do
    GenServer.cast(__MODULE__, {:release, path, self()})
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{locks: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, path}, {pid, _tag} = from, state) do
    locks = state.locks
    state = ensure_monitored(state, pid)

    case Map.get(locks, path) do
      nil ->
        # Lock is free, grant it immediately
        new_locks = Map.put(locks, path, {pid, []})
        {:reply, :ok, %{state | locks: new_locks}}

      {owner, waiters} ->
        # Lock is held, queue the client
        new_waiters = waiters ++ [from]
        new_locks = Map.put(locks, path, {owner, new_waiters})
        {:noreply, %{state | locks: new_locks}}
    end
  end

  @impl true
  def handle_cast({:release, path, pid}, state) do
    {:noreply, do_release(state, path, pid)}
  end

  @impl true
  def handle_cast({:cancel, path, pid}, state) do
    {:noreply, do_cancel(state, path, pid)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove monitor registration
    state = %{state | monitors: Map.delete(state.monitors, pid)}

    # Release any locks held by the crashed process, and remove it from any waiter lists
    new_locks =
      Enum.reduce(state.locks, %{}, fn {path, {owner, waiters}}, acc ->
        cond do
          owner == pid ->
            case waiters do
              [] ->
                acc

              [next_from | rest] ->
                GenServer.reply(next_from, :ok)
                {next_pid, _} = next_from
                Map.put(acc, path, {next_pid, rest})
            end

          true ->
            new_waiters = Enum.reject(waiters, fn {w_pid, _} -> w_pid == pid end)
            Map.put(acc, path, {owner, new_waiters})
        end
      end)

    {:noreply, gc_monitors(%{state | locks: new_locks})}
  end

  # Helpers

  defp ensure_monitored(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  defp do_release(state, path, pid) do
    locks = state.locks

    case Map.get(locks, path) do
      {^pid, []} ->
        new_locks = Map.delete(locks, path)
        gc_monitors(%{state | locks: new_locks})

      {^pid, [next_from | rest]} ->
        GenServer.reply(next_from, :ok)
        {next_pid, _} = next_from
        new_locks = Map.put(locks, path, {next_pid, rest})
        gc_monitors(%{state | locks: new_locks})

      _ ->
        state
    end
  end

  defp do_cancel(state, path, pid) do
    locks = state.locks

    case Map.get(locks, path) do
      nil ->
        state

      {^pid, []} ->
        new_locks = Map.delete(locks, path)
        gc_monitors(%{state | locks: new_locks})

      {^pid, [next_from | rest]} ->
        GenServer.reply(next_from, :ok)
        {next_pid, _} = next_from
        new_locks = Map.put(locks, path, {next_pid, rest})
        gc_monitors(%{state | locks: new_locks})

      {owner, waiters} ->
        new_waiters = Enum.reject(waiters, fn {w_pid, _} -> w_pid == pid end)
        new_locks = Map.put(locks, path, {owner, new_waiters})
        gc_monitors(%{state | locks: new_locks})
    end
  end

  defp gc_monitors(state) do
    active_pids =
      Enum.reduce(state.locks, MapSet.new(), fn {_path, {owner, waiters}}, acc ->
        acc
        |> MapSet.put(owner)
        |> MapSet.union(MapSet.new(Enum.map(waiters, fn {w_pid, _} -> w_pid end)))
      end)

    new_monitors =
      Enum.reduce(state.monitors, %{}, fn {pid, ref}, acc ->
        if MapSet.member?(active_pids, pid) do
          Map.put(acc, pid, ref)
        else
          Process.demonitor(ref, [:flush])
          acc
        end
      end)

    %{state | monitors: new_monitors}
  end
end
