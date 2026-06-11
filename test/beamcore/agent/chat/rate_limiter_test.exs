defmodule Beamcore.Agent.Chat.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Beamcore.RateLimiter

  test "with interval 0, wait/0 returns immediately and does not sleep" do
    start_time = System.monotonic_time(:millisecond)
    # The global RateLimiter in test env has interval 0
    assert :ok == RateLimiter.wait()
    assert :ok == RateLimiter.wait()
    assert :ok == RateLimiter.wait()
    end_time = System.monotonic_time(:millisecond)

    # Should be extremely fast (less than 10ms)
    assert end_time - start_time < 10
  end

  test "with non-zero interval, paces requests correctly" do
    # Start a custom rate limiter with a 50ms interval to avoid interfering with the global one
    {:ok, pid} = GenServer.start_link(RateLimiter, interval: 50)

    start_time = System.monotonic_time(:millisecond)

    # First call should be instant
    assert :ok == GenServer.call(pid, :wait)
    first_duration = System.monotonic_time(:millisecond) - start_time
    assert first_duration < 15

    # Second call should block to respect the 50ms interval
    assert :ok == GenServer.call(pid, :wait)
    total_duration = System.monotonic_time(:millisecond) - start_time

    # Total duration must be at least 50ms (giving a tiny buffer for Process.sleep resolution)
    assert total_duration >= 45

    # Third call in rapid succession should also block
    assert :ok == GenServer.call(pid, :wait)
    total_duration_3 = System.monotonic_time(:millisecond) - start_time
    assert total_duration_3 >= 90

    # Cleanup
    GenServer.stop(pid)
  end

  test "server remains responsive while a caller waits for a reserved slot" do
    {:ok, pid} = GenServer.start_link(RateLimiter, interval: 80)

    assert :ok == GenServer.call(pid, :wait)

    caller =
      Task.async(fn ->
        GenServer.call(pid, :wait, :infinity)
      end)

    Process.sleep(10)

    assert %{interval: 80} = :sys.get_state(pid, 50)
    assert :ok == Task.await(caller, 200)

    GenServer.stop(pid)
  end

  test "concurrent callers are released sequentially with one active timer" do
    {:ok, pid} = GenServer.start_link(RateLimiter, interval: 60)

    assert :ok == GenServer.call(pid, :wait)

    callers =
      for _index <- 1..3 do
        Task.async(fn ->
          :ok = GenServer.call(pid, :wait, :infinity)
          System.monotonic_time(:millisecond)
        end)
      end

    Process.sleep(10)

    state = :sys.get_state(pid, 50)
    assert :queue.len(state.waiting) == 3
    assert is_reference(state.timer_ref)

    [first, second, third] =
      callers
      |> Enum.map(&Task.await(&1, 300))
      |> Enum.sort()

    assert second - first >= 45
    assert third - second >= 45

    assert %{timer_ref: nil} = :sys.get_state(pid, 50)

    GenServer.stop(pid)
  end

  test "stale release messages do not release queued callers early" do
    {:ok, pid} = GenServer.start_link(RateLimiter, interval: 200)

    assert :ok == GenServer.call(pid, :wait)

    caller =
      Task.async(fn ->
        GenServer.call(pid, :wait, :infinity)
      end)

    Process.sleep(10)

    send(pid, :release_next)
    send(pid, {:release_next, make_ref(), System.monotonic_time(:millisecond)})

    refute Task.yield(caller, 50)
    assert :ok == Task.await(caller, 500)

    GenServer.stop(pid)
  end

  test "wait/0 returns ok when the registered limiter is not running" do
    stop_rate_limiter!()

    try do
      assert :ok == RateLimiter.wait()
    after
      restart_rate_limiter!()
    end
  end

  test "when rate limiter process is running, returns pid" do
    assert is_pid(Process.whereis(Beamcore.RateLimiter))
  end

  defp stop_rate_limiter! do
    case Process.whereis(Beamcore.RateLimiter) do
      nil ->
        :ok

      _pid ->
        :ok = Supervisor.terminate_child(Beamcore.Agent.Supervisor, Beamcore.RateLimiter)
    end
  end

  defp restart_rate_limiter! do
    case Process.whereis(Beamcore.RateLimiter) do
      nil -> Supervisor.restart_child(Beamcore.Agent.Supervisor, Beamcore.RateLimiter)
      _pid -> :ok
    end
  end
end
