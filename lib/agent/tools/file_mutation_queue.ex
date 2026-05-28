defmodule Beamcore.Agent.Tools.FileMutationQueue do
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

  def acquire_lock(path, timeout) do
    ref = make_ref()

    try do
      GenServer.call(__MODULE__, {:acquire, path, self(), ref}, timeout)

      receive do
        {:lock_granted, ^ref} ->
          :ok
      after
        timeout ->
          GenServer.cast(__MODULE__, {:cancel, path, self()})
          {:error, :timeout}
      end
    catch
      :exit, {:timeout, _} ->
        {:error, :timeout}
    end
  end

  def release_lock(path) do
    GenServer.cast(__MODULE__, {:release, path, self()})
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{locks: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, path, pid, ref}, _from, state) do
    locks = state.locks
    monitors = state.monitors

    case Map.get(locks, path) do
      nil ->
        send(pid, {:lock_granted, ref})

        new_monitors =
          if Map.has_key?(monitors, pid) do
            monitors
          else
            m_ref = Process.monitor(pid)
            Map.put(monitors, pid, m_ref)
          end

        new_locks = Map.put(locks, path, {pid, ref, []})
        {:reply, :ok, %{state | locks: new_locks, monitors: new_monitors}}

      {owner, owner_ref, waiters} ->
        new_waiters = waiters ++ [{pid, ref}]
        new_locks = Map.put(locks, path, {owner, owner_ref, new_waiters})
        {:reply, :ok, %{state | locks: new_locks}}
    end
  end

  @impl true
  def handle_cast({:release, path, pid}, state) do
    {:noreply, do_release(state, path, pid)}
  end

  @impl true
  def handle_cast({:cancel, path, pid}, state) do
    locks = state.locks

    case Map.get(locks, path) do
      nil ->
        {:noreply, state}

      {^pid, _ref, []} ->
        new_locks = Map.delete(locks, path)
        {:noreply, %{state | locks: new_locks}}

      {^pid, _ref, [{next_pid, next_ref} | rest_waiters]} ->
        send(next_pid, {:lock_granted, next_ref})
        new_locks = Map.put(locks, path, {next_pid, next_ref, rest_waiters})

        new_monitors =
          if Map.has_key?(state.monitors, next_pid) do
            state.monitors
          else
            m_ref = Process.monitor(next_pid)
            Map.put(state.monitors, next_pid, m_ref)
          end

        {:noreply, %{state | locks: new_locks, monitors: new_monitors}}

      {owner, owner_ref, waiters} ->
        new_waiters = Enum.reject(waiters, fn {w_pid, _w_ref} -> w_pid == pid end)
        new_locks = Map.put(locks, path, {owner, owner_ref, new_waiters})
        {:noreply, %{state | locks: new_locks}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_monitors = Map.delete(state.monitors, pid)

    new_locks =
      Enum.reduce(state.locks, state.locks, fn {path, {owner, _owner_ref, _waiters}}, acc ->
        if owner == pid do
          release_locks_for_pid(acc, path, pid)
        else
          acc
        end
      end)

    {:noreply, %{state | locks: new_locks, monitors: new_monitors}}
  end

  # Helpers

  defp do_release(state, path, pid) do
    locks = state.locks

    case Map.get(locks, path) do
      {^pid, _ref, []} ->
        new_locks = Map.delete(locks, path)
        %{state | locks: new_locks}

      {^pid, _ref, [{next_pid, next_ref} | rest_waiters]} ->
        send(next_pid, {:lock_granted, next_ref})
        new_locks = Map.put(locks, path, {next_pid, next_ref, rest_waiters})

        new_monitors =
          if Map.has_key?(state.monitors, next_pid) do
            state.monitors
          else
            m_ref = Process.monitor(next_pid)
            Map.put(state.monitors, next_pid, m_ref)
          end

        %{state | locks: new_locks, monitors: new_monitors}

      _ ->
        state
    end
  end

  defp release_locks_for_pid(locks, path, pid) do
    case Map.get(locks, path) do
      {^pid, _ref, []} ->
        Map.delete(locks, path)

      {^pid, _ref, [{next_pid, next_ref} | rest_waiters]} ->
        send(next_pid, {:lock_granted, next_ref})
        Map.put(locks, path, {next_pid, next_ref, rest_waiters})

      _ ->
        locks
    end
  end
end
