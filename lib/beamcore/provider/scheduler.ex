defmodule Beamcore.Provider.Scheduler do
  @moduledoc """
  Provider-neutral request gate keyed by provider/account/model.

  A cooldown on one key never blocks unrelated keys.
  """

  use GenServer

  @type key :: {atom(), binary() | nil, binary() | nil}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec wait(key(), keyword()) :: :ok
  def wait(key, opts \\ []) do
    delay = reserve(key, opts)

    if delay > 0 do
      wait_fun = Keyword.get(opts, :wait_fun) || (&Process.sleep/1)
      wait_fun.(delay)
    end

    :ok
  end

  @spec reserve(key(), keyword()) :: non_neg_integer()
  def reserve(key, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if Process.whereis(name) do
      GenServer.call(name, {:reserve, key, opts}, :infinity)
    else
      0
    end
  end

  @spec cooldown(key(), non_neg_integer(), keyword()) :: :ok
  def cooldown(key, milliseconds, opts \\ [])
      when is_integer(milliseconds) and milliseconds >= 0 do
    name = Keyword.get(opts, :name, __MODULE__)

    if Process.whereis(name) do
      GenServer.call(name, {:cooldown, key, milliseconds}, :infinity)
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       default_interval: Keyword.get(opts, :default_interval, 0),
       keys: %{}
     }}
  end

  @impl true
  def handle_call({:reserve, key, opts}, _from, state) do
    interval = Keyword.get(opts, :interval, state.default_interval)
    now = now()
    entry = Map.get(state.keys, key, entry(interval))
    entry = %{entry | interval: interval}
    earliest = earliest_release(entry, now)
    release_at = max(now, earliest)
    delay = max(release_at - now, 0)

    entry = %{
      entry
      | interval: interval,
        last_request_time: release_at,
        cooldown_until: clear_elapsed_cooldown(entry.cooldown_until, release_at)
    }

    {:reply, delay, put_entry(state, key, entry)}
  end

  def handle_call({:cooldown, key, milliseconds}, _from, state) do
    now = now()
    entry = Map.get(state.keys, key, entry(state.default_interval))
    cooldown_until = now + milliseconds

    entry = %{
      entry
      | cooldown_until: max_timestamp(entry.cooldown_until, cooldown_until)
    }

    {:reply, :ok, put_entry(state, key, entry)}
  end

  defp entry(interval) do
    %{
      interval: interval,
      last_request_time: nil,
      cooldown_until: nil
    }
  end

  defp earliest_release(%{last_request_time: nil, cooldown_until: nil}, now), do: now

  defp earliest_release(%{last_request_time: nil, cooldown_until: cooldown_until}, _now),
    do: cooldown_until

  defp earliest_release(entry, _now) do
    interval_at = (entry.last_request_time || 0) + entry.interval

    case entry.cooldown_until do
      nil -> interval_at
      cooldown_until -> max(interval_at, cooldown_until)
    end
  end

  defp clear_elapsed_cooldown(nil, _release_at), do: nil

  defp clear_elapsed_cooldown(cooldown_until, release_at) do
    if cooldown_until <= release_at, do: nil, else: cooldown_until
  end

  defp max_timestamp(nil, timestamp), do: timestamp
  defp max_timestamp(existing, timestamp), do: max(existing, timestamp)

  defp put_entry(state, key, entry), do: %{state | keys: Map.put(state.keys, key, entry)}
  defp now, do: System.monotonic_time(:millisecond)
end
