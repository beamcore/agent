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
    Process.put(:workspace_root, workspace_root)

    run = fn ->
      max_output = Keyword.fetch!(opts, :max_output_bytes)

      {:ok, io} =
        Beamcore.Agent.Tools.Eeva.IODevice.start_link(max_output)

      {:ok, stderr_io} =
        Beamcore.Agent.Tools.Eeva.IODevice.start_link(max_output)

      previous_group_leader = Process.group_leader()
      Process.group_leader(self(), io)

      previous_stdin = swap_registered_name(:standard_io, io)
      previous_stderr = swap_registered_name(:standard_error, stderr_io)

      try do
        {eval_result, diagnostics} =
          Code.with_diagnostics(fn ->
            {value, _binding} =
              Code.eval_quoted(Keyword.fetch!(opts, :quoted), [], file: "eeva", line: 1)

            if is_function(value, 0), do: value.(), else: value
          end)

        stdout = Beamcore.Agent.Tools.Eeva.IODevice.output(io)
        stderr = Beamcore.Agent.Tools.Eeva.IODevice.output(stderr_io)
        output = merge_captured_output(stdout, stderr, diagnostics)

        %{
          status: :ok,
          output: output,
          result:
            eval_result
            |> inspect(
              pretty: true,
              limit: 100,
              printable_limit: Keyword.fetch!(opts, :max_result_bytes)
            )
            |> limit_binary(Keyword.fetch!(opts, :max_result_bytes))
        }
      catch
        kind, error ->
          stdout = Beamcore.Agent.Tools.Eeva.IODevice.output(io)
          stderr = Beamcore.Agent.Tools.Eeva.IODevice.output(stderr_io)
          output = merge_captured_output(stdout, stderr, [])

          %{
            status: :error,
            output: output,
            kind: kind,
            error: error,
            stacktrace: __STACKTRACE__
          }
      after
        Process.group_leader(self(), previous_group_leader)
        restore_registered_name(:standard_io, previous_stdin)
        restore_registered_name(:standard_error, previous_stderr)
        stop_io_device(io)
        stop_io_device(stderr_io)
      end
    end

    with_serialized_cwd(workspace_root, run)
  end

  # cwd is per-VM, so the lock is node-local rather than cluster-wide. Every eval
  # enters the workspace and exits back to the launch directory — a stable,
  # never-deleted reference — instead of re-reading the current cwd, which a
  # previously killed eval may have left pointing at a since-deleted dir.
  defp with_serialized_cwd(workspace_root, fun) do
    home = home_cwd()

    :global.trans(
      {__MODULE__, :cwd},
      fn ->
        if File.dir?(workspace_root) do
          File.cd!(workspace_root)
        else
          Beamcore.AppLog.warn("Workspace root does not exist, using current dir",
            workspace_root: workspace_root
          )
        end

        try do
          fun.()
        after
          cd_if_dir(home)
        end
      end,
      [node()]
    )
  end

  # The launch directory, captured at application start. Stable for the life of
  # the VM, so it's the safe target to return to after every eval.
  defp home_cwd do
    Application.get_env(:beamcore, :initial_workspace_root) || safe_cwd()
  end

  defp safe_cwd do
    case File.cwd() do
      {:ok, cwd} ->
        cwd

      {:error, _reason} ->
        Beamcore.Agent.Tools.PathInput.workspace_root()
    end
  end

  defp cd_if_dir(dir) when is_binary(dir) do
    if File.dir?(dir), do: File.cd!(dir)
    :ok
  rescue
    _ -> :ok
  end

  defp cd_if_dir(_), do: :ok

  # Temporarily replace a named process (e.g. :standard_io, :standard_error)
  # with new_pid. Returns the previous pid, or nil if none was registered.
  defp swap_registered_name(name, new_pid) do
    previous = Process.whereis(name)

    if previous do
      Process.unregister(name)
    end

    Process.register(new_pid, name)
    previous
  rescue
    _ -> nil
  end

  defp restore_registered_name(name, nil) do
    try do
      Process.unregister(name)
    rescue
      _ -> :ok
    end

    register_fallback(name)
    :ok
  end

  defp restore_registered_name(name, previous) do
    try do
      Process.unregister(name)
    rescue
      _ -> :ok
    end

    if Process.alive?(previous) do
      Process.register(previous, name)
    else
      register_fallback(name)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp register_fallback(name) do
    fallback = Process.group_leader()

    if is_pid(fallback) and Process.alive?(fallback) do
      Process.register(fallback, name)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp merge_captured_output(stdout, stderr, diagnostics) do
    diag_text = format_diagnostics(diagnostics)

    parts =
      [stdout, stderr, diag_text]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.map(&Beamcore.Text.sanitize/1)

    Enum.join(parts, "\n")
  end

  defp format_diagnostics([]), do: ""

  defp format_diagnostics(diagnostics) do
    diagnostics
    |> Enum.map(fn diag ->
      severity = Map.get(diag, :severity, :warning)
      message = Map.get(diag, :message, "")
      position = Map.get(diag, :position, nil)

      pos_str =
        case position do
          line when is_integer(line) -> "eeva:#{line}: "
          {line, col} -> "eeva:#{line}:#{col}: "
          _ -> ""
        end

      "#{pos_str}#{severity}: #{message}"
    end)
    |> Enum.join("\n")
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
      kill: true
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
    ensure_home_cwd()

    if state.waiter do
      GenServer.reply(state.waiter, result)
      {:stop, :normal, %{state | result: result}}
    else
      retention_ref = Process.send_after(self(), :expire_result, @result_retention_ms)
      {:noreply, %{state | result: result, retention_ref: retention_ref}}
    end
  end

  # Backstop for the kill paths: a timed-out or over-budget eval is killed before
  # its own `after` can run, leaving the VM cwd in the (possibly since-deleted)
  # workspace. The worker survives the kill, so it restores cwd here. The happy
  # path is already home, so it skips without taking the lock; only the kill
  # paths take the (bounded, node-local) lock to avoid yanking a concurrent eval.
  defp ensure_home_cwd do
    home = home_cwd()

    case File.cwd() do
      {:ok, cwd} -> unless Path.expand(cwd) == home, do: locked_restore(home)
      {:error, _reason} -> locked_restore(home)
    end
  end

  defp locked_restore(home) do
    :global.trans({__MODULE__, :cwd}, fn -> cd_if_dir(home) end, [node()], 5)
    :ok
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
