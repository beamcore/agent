defmodule Beamcore.Provider.Health do
  @moduledoc """
  Supervised provider discovery and health cache.

  Network probes run under `Beamcore.Agent.TaskSupervisor`; callers never own
  discovery processes and repeated requests share a short-lived cache. A local
  helper failure is isolated from the primary chat runtime.
  """

  use GenServer

  @default_ttl_ms 10_000
  @default_timeout_ms 1_500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def list_models(provider, opts \\ []) when is_binary(provider) do
    call({:models, provider}, opts, {:error, :unavailable})
  end

  def model_available?(provider, model, opts \\ [])
      when is_binary(provider) and is_binary(model) do
    case list_models(provider, opts) do
      {:ok, models} -> model in models
      _ -> false
    end
  end

  def invalidate(provider \\ :all) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:invalidate, provider})
    :ok
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       cache: %{},
       pending: %{},
       ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
       timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
       task_supervisor: Keyword.get(opts, :task_supervisor, Beamcore.Agent.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call({:models, provider}, from, state) do
    key = {:models, provider}

    case cached(state, key) do
      {:ok, value} ->
        {:reply, value, state}

      :miss ->
        case Map.get(state.pending, key) do
          nil -> {:noreply, start_probe(state, key, from, provider)}
          pending -> {:noreply, put_in(state.pending[key].waiters, [from | pending.waiters])}
        end
    end
  end

  @impl true
  def handle_cast({:invalidate, :all}, state), do: {:noreply, %{state | cache: %{}}}

  def handle_cast({:invalidate, provider}, state) do
    cache = Map.drop(state.cache, [{:models, provider}])
    {:noreply, %{state | cache: cache}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case pending_by_ref(state.pending, ref) do
      {key, pending} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(pending.timer)
        Enum.each(pending.waiters, &GenServer.reply(&1, result))

        cache = Map.put(state.cache, key, {expires_at(state.ttl_ms), result})
        {:noreply, %{state | cache: cache, pending: Map.delete(state.pending, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:probe_timeout, key, ref}, state) do
    case Map.get(state.pending, key) do
      %{task: %{ref: ^ref} = task, waiters: waiters} ->
        Task.shutdown(task, :brutal_kill)
        Enum.each(waiters, &GenServer.reply(&1, {:error, :timeout}))
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pending_by_ref(state.pending, ref) do
      {key, pending} ->
        Enum.each(pending.waiters, &GenServer.reply(&1, {:error, normalize_down(reason)}))
        Process.cancel_timer(pending.timer)
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      nil ->
        {:noreply, state}
    end
  end

  defp call(message, opts, fallback) do
    name = Keyword.get(opts, :name, __MODULE__)
    timeout = Keyword.get(opts, :call_timeout, @default_timeout_ms + 500)

    if Process.whereis(name) do
      GenServer.call(name, message, timeout)
    else
      fallback
    end
  catch
    :exit, _ -> fallback
  end

  defp start_probe(state, key, from, provider_name) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        discover_models(provider_name)
      end)

    timer = Process.send_after(self(), {:probe_timeout, key, task.ref}, state.timeout_ms)
    pending = %{task: task, waiters: [from], timer: timer}
    put_in(state.pending[key], pending)
  end

  defp discover_models(provider_name) do
    case Beamcore.Provider.Registry.get(provider_name) do
      nil ->
        {:error, :unknown_provider}

      %{discovery: discovery, base_url: base_url}
      when is_atom(discovery) and not is_nil(discovery) ->
        discovery.list_models(base_url)

      %{default_model: model} when is_binary(model) ->
        {:ok, [model]}

      _ ->
        {:ok, []}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp cached(cache, key) do
    now = now_ms()

    case Map.get(cache, key) do
      {expires, value} when expires > now ->
        {:ok, value}

      _ ->
        :miss
    end
  end

  defp pending_by_ref(pending, ref) do
    Enum.find_value(pending, fn {key, value} ->
      if value.task.ref == ref, do: {key, value}, else: nil
    end)
  end

  defp expires_at(ttl), do: now_ms() + ttl
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp normalize_down(:normal), do: :unavailable
  defp normalize_down(reason), do: reason
end
