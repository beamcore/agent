defmodule Beamcore.Agent.Chat.RateLimiter do
  use GenServer

  @moduledoc """
  A simple rate limiter to ensure we don't exceed the Mistral API rate limit (1 request per second).
  """

  # Client API

  @doc """
  Starts the rate limiter.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Blocks the calling process if necessary to ensure at least the configured interval has elapsed since the last API request started.
  """
  def wait do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :wait, :infinity)
    else
      :ok
    end
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval) || Application.get_env(:agent, :rate_limit_ms, 1000)
    {:ok, %{last_request_time: nil, interval: interval}}
  end

  @impl true
  def handle_call(:wait, _from, %{interval: 0} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:wait, _from, %{last_request_time: nil} = state) do
    now = System.monotonic_time(:millisecond)
    {:reply, :ok, %{state | last_request_time: now}}
  end

  def handle_call(:wait, _from, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_request_time

    if elapsed >= state.interval do
      # More than interval has passed, proceed immediately
      {:reply, :ok, %{state | last_request_time: now}}
    else
      # Need to wait
      wait_time = state.interval - elapsed
      Process.sleep(wait_time)
      # Record the logical start time of this request as if it started after the wait_time
      {:reply, :ok, %{state | last_request_time: now + wait_time}}
    end
  end
end
