defmodule Beamcore.FileMutationQueueTest do
  use ExUnit.Case, async: true

  alias Beamcore.FileMutationQueue

  test "acquires and releases lock successfully" do
    path = "test_file_1.txt"
    assert :ok = FileMutationQueue.acquire_lock(path, 1000)
    assert :ok = FileMutationQueue.release_lock(path)
  end

  test "with_lock runs block and releases lock" do
    path = "test_file_2.txt"

    assert :ok =
             FileMutationQueue.with_lock(path, 1000, fn ->
               # Perform operation inside lock
               :ok
             end)
  end

  test "blocks concurrent waiters until released" do
    path = "test_file_3.txt"
    parent = self()

    # Process 1 acquires lock
    assert :ok = FileMutationQueue.acquire_lock(path, 1000)

    # Spawn Process 2 which tries to acquire lock and notifies parent when done
    spawn_link(fn ->
      res = FileMutationQueue.acquire_lock(path, 2000)
      send(parent, {:p2_lock_result, res})

      if res == :ok do
        FileMutationQueue.release_lock(path)
      end
    end)

    # Process 2 should be blocked. We wait 100ms and verify no message is received.
    refute_receive {:p2_lock_result, _}, 100

    # Process 1 releases lock
    assert :ok = FileMutationQueue.release_lock(path)

    # Process 2 should now acquire lock and send the message
    assert_receive {:p2_lock_result, :ok}, 500
  end

  test "times out when lock is held too long" do
    path = "test_file_4.txt"
    parent = self()

    # Process 1 acquires lock
    assert :ok = FileMutationQueue.acquire_lock(path, 1000)

    # Spawn Process 2 which tries to acquire lock with short timeout
    spawn_link(fn ->
      res = FileMutationQueue.acquire_lock(path, 100)
      send(parent, {:p2_lock_result, res})
    end)

    # Process 2 should time out
    assert_receive {:p2_lock_result, {:error, :timeout}}, 300

    # Process 1 releases lock
    assert :ok = FileMutationQueue.release_lock(path)
  end

  test "releases lock when the owner process crashes" do
    path = "test_file_5.txt"
    parent = self()

    # Spawn Process 1 to acquire lock and then crash
    {pid, ref} =
      spawn_monitor(fn ->
        assert :ok = FileMutationQueue.acquire_lock(path, 1000)
        send(parent, :p1_has_lock)
        # Block until told to exit
        receive do
          :exit -> :ok
        end
      end)

    assert_receive :p1_has_lock, 500

    # Spawn Process 2 which tries to acquire lock (currently blocked)
    spawn_link(fn ->
      res = FileMutationQueue.acquire_lock(path, 1000)
      send(parent, {:p2_lock_result, res})
      if res == :ok, do: FileMutationQueue.release_lock(path)
    end)

    refute_receive {:p2_lock_result, _}, 100

    # Kill Process 1
    send(pid, :exit)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

    # Process 2 should now succeed
    assert_receive {:p2_lock_result, :ok}, 500
  end
end
