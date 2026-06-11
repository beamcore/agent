defmodule Beamcore.RateLimiter do
  use GenServer

  @moduledoc """
  A simple rate limiter to ensure we don't exceed API rate limits.
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

    {:ok,
     %{
       last_request_time: nil,
       interval: interval,
       waiting: :queue.new(),
       timer_ref: nil
     }}
  end

  @impl true
  def handle_call(:wait, _from, %{interval: 0} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:wait, _from, %{last_request_time: nil, timer_ref: nil} = state) do
    now = System.monotonic_time(:millisecond)
    {:reply, :ok, %{state | last_request_time: now}}
  end

  def handle_call(:wait, from, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_request_time

    if elapsed >= state.interval and :queue.is_empty(state.waiting) do
      # More than interval has passed, proceed immediately
      {:reply, :ok, %{state | last_request_time: now}}
    else
      state =
        state
        |> enqueue_waiter(from)
        |> ensure_timer(now)

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:release_next, ref, release_at}, %{timer_ref: ref} = state) do
    case :queue.out(state.waiting) do
      {{:value, from}, waiting} ->
        GenServer.reply(from, :ok)

        state = %{state | waiting: waiting, last_request_time: release_at, timer_ref: nil}

        {:noreply, ensure_timer(state, System.monotonic_time(:millisecond))}

      {:empty, waiting} ->
        {:noreply, %{state | waiting: waiting, timer_ref: nil}}
    end
  end

  def handle_info({:release_next, _ref, _release_at}, state), do: {:noreply, state}
  def handle_info(:release_next, state), do: {:noreply, state}

  defp enqueue_waiter(state, from), do: %{state | waiting: :queue.in(from, state.waiting)}

  defp ensure_timer(%{timer_ref: ref} = state, _now) when not is_nil(ref), do: state

  defp ensure_timer(%{waiting: waiting} = state, _now) do
    if :queue.is_empty(waiting) do
      state
    else
      {wait_time, release_at} = release_schedule(state)
      ref = make_ref()
      Process.send_after(self(), {:release_next, ref, release_at}, wait_time)
      %{state | timer_ref: ref}
    end
  end

  defp release_schedule(%{last_request_time: nil}) do
    now = System.monotonic_time(:millisecond)
    {0, now}
  end

  defp release_schedule(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_request_time
    wait_time = max(state.interval - elapsed, 0)
    {wait_time, now + wait_time}
  end
end
