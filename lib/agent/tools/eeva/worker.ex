defmodule Beamcore.Agent.Tools.Eeva.Worker do
  @moduledoc """
  Temporary OTP worker which owns one Eeva evaluation.

  The evaluated program runs as a supervised task. This GenServer owns the
  timeout, resource sampling, result delivery, and task termination lifecycle.
  """

  use GenServer

  @sample_interval_ms 20
  @result_retention_ms 30_000

  defstruct [
    :task,
    :task_ref,
    :owner_ref,
    :waiter,
    :timeout_ref,
    :sample_ref,
    :retention_ref,
    :timeout_ms,
    :max_memory_bytes,
    :max_reductions,
    :result
  ]

  def child_spec(opts) do
    %{
      id: {__MODULE__, System.unique_integer([:positive, :monotonic])},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 1_000,
      type: :worker
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def await(pid), do: GenServer.call(pid, :await, :infinity)

  @impl true
  def init(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    owner = Keyword.fetch!(opts, :owner)
    owner_ref = Process.monitor(owner)

    case start_task(fn -> evaluate(opts) end) do
      {:ok, task} ->
        {:ok,
         %__MODULE__{
           task: task,
           task_ref: task.ref,
           owner_ref: owner_ref,
           timeout_ref: Process.send_after(self(), :timeout, timeout_ms),
           sample_ref: Process.send_after(self(), :sample, @sample_interval_ms),
           timeout_ms: timeout_ms,
           max_memory_bytes: Keyword.fetch!(opts, :max_memory_bytes),
           max_reductions: Keyword.fetch!(opts, :max_reductions)
         }}

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:await, from, %{result: nil, waiter: nil} = state) do
    {:noreply, %{state | waiter: from}}
  end

  def handle_call(:await, _from, %{result: nil} = state) do
    {:reply, {:error, :already_awaited, :eeva_execution}, state}
  end

  def handle_call(:await, _from, %{result: result} = state) do
    {:stop, :normal, result, state}
  end

  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    finish({:ok, result}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    finish({:error, :worker_exit, reason}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_ref: ref} = state) do
    terminate_task(state.task)
    finish({:error, :owner_down, reason}, state)
  end

  def handle_info(:timeout, state) do
    terminate_task(state.task)
    finish({:error, :timeout, state.timeout_ms}, state)
  end

  def handle_info(:sample, state) do
    case resource_usage(state.task.pid) do
      {:ok, memory, _reductions} when memory > state.max_memory_bytes ->
        terminate_task(state.task)
        finish({:error, :memory_limit, memory}, state)

      {:ok, _memory, reductions} when reductions > state.max_reductions ->
        terminate_task(state.task)
        finish({:error, :reduction_limit, reductions}, state)

      {:ok, _memory, _reductions} ->
        sample_ref = Process.send_after(self(), :sample, @sample_interval_ms)
        {:noreply, %{state | sample_ref: sample_ref}}

      {:error, :not_alive} ->
        # The normal task result or DOWN message is already in flight.
        {:noreply, %{state | sample_ref: nil}}
    end
  end

  def handle_info(:expire_result, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timeout_ref)
    cancel_timer(state.sample_ref)
    cancel_timer(state.retention_ref)
    demonitor(state.owner_ref)
    terminate_task(state.task)
    :ok
  end

  defp evaluate(opts) do
    configure_heap_limit(Keyword.fetch!(opts, :max_memory_bytes))
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    policy = Keyword.fetch!(opts, :policy)

    Process.put(:workspace_root, workspace_root)
    Process.put(:beamcore_tool_policy, policy)
    Beamcore.Agent.Tools.Eeva.Policy.install(policy, workspace_root)

    filesystem_context = Keyword.get(opts, :filesystem_context)

    run = fn ->
      {:ok, io} =
        Beamcore.Agent.Tools.Eeva.IODevice.start_link(Keyword.fetch!(opts, :max_output_bytes))

      previous_group_leader = Process.group_leader()
      Process.group_leader(self(), io)

      try do
        {value, _binding} =
          Code.eval_quoted(Keyword.fetch!(opts, :quoted), [], file: "eeva", line: 1)

        value = if is_function(value, 0), do: value.(), else: value

        %{
          status: :ok,
          output: Beamcore.Agent.Tools.Eeva.IODevice.output(io),
          result:
            value
            |> inspect(
              pretty: true,
              limit: 100,
              printable_limit: Keyword.fetch!(opts, :max_result_bytes)
            )
            |> limit_binary(Keyword.fetch!(opts, :max_result_bytes))
        }
      catch
        kind, error ->
          %{
            status: :error,
            output: Beamcore.Agent.Tools.Eeva.IODevice.output(io),
            kind: kind,
            error: error,
            stacktrace: __STACKTRACE__
          }
      after
        Process.group_leader(self(), previous_group_leader)
        stop_io_device(io)
      end
    end

    authorized_run = fn ->
      if Beamcore.Agent.Chat.ToolPolicy.project_policy_bypassed?(policy) do
        Beamcore.Agent.Policy.ProjectPolicy.with_bypass(run)
      else
        run.()
      end
    end

    try do
      if filesystem_context do
        Beamcore.Agent.FilesystemJournal.with_context(filesystem_context, authorized_run)
      else
        authorized_run.()
      end
    after
      Beamcore.Agent.Tools.Eeva.Policy.clear()
    end
  end

  defp stop_io_device(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    _, _ -> :ok
  end

  defp configure_heap_limit(max_memory_bytes) do
    word_size = :erlang.system_info(:wordsize)
    max_words = max(div(max_memory_bytes, word_size), 1_024)

    Process.flag(:max_heap_size, %{
      size: max_words,
      kill: true,
      error_logger: false
    })
  end

  defp start_task(fun) do
    case Process.whereis(Beamcore.Agent.TaskSupervisor) do
      nil ->
        {:error, :task_supervisor_not_started}

      _pid ->
        {:ok, Task.Supervisor.async_nolink(Beamcore.Agent.TaskSupervisor, fun)}
    end
  end

  defp terminate_task(%Task{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      Task.Supervisor.terminate_child(Beamcore.Agent.TaskSupervisor, pid)
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp terminate_task(_task), do: :ok

  defp resource_usage(pid) when is_pid(pid) do
    case Process.info(pid, [:memory, :reductions]) do
      nil -> {:error, :not_alive}
      info -> {:ok, Keyword.get(info, :memory, 0), Keyword.get(info, :reductions, 0)}
    end
  end

  defp finish(result, state) do
    cancel_timer(state.timeout_ref)
    cancel_timer(state.sample_ref)

    if state.waiter do
      GenServer.reply(state.waiter, result)
      {:stop, :normal, %{state | result: result}}
    else
      retention_ref = Process.send_after(self(), :expire_result, @result_retention_ms)
      {:noreply, %{state | result: result, retention_ref: retention_ref}}
    end
  end

  defp limit_binary(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp limit_binary(binary, max_bytes) do
    suffix = "\n...[result truncated]"
    kept = max(max_bytes - byte_size(suffix), 0)
    safe_binary_prefix(binary, kept) <> suffix
  end

  defp safe_binary_prefix(binary, max_bytes) do
    candidate = binary_part(binary, 0, min(byte_size(binary), max_bytes))

    if String.valid?(candidate) do
      candidate
    else
      safe_binary_prefix(candidate, max(byte_size(candidate) - 1, 0))
    end
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref, async: true, info: false)
end
