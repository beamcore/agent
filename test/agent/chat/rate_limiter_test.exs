defmodule Beamcore.Agent.Chat.RateLimiterTest do
  use ExUnit.Case, async: true

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

  test "when rate limiter process is running, returns pid" do
    assert is_pid(Process.whereis(Beamcore.RateLimiter))
  end
end
