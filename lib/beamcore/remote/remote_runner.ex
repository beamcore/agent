defmodule Beamcore.RemoteRunner do
  @moduledoc """
  Self-contained Eeva evaluator that runs **inside an attached project node**.

  When BeamCore is attached to a target node, the prepared Elixir AST is shipped
  to that node and evaluated here, so the project's own modules, dependencies and
  running applications are in scope. This is what gives the live-runtime
  experience for any project, not just BeamCore developing itself.

  ## Why this module is special

  This module is **injected** onto the target node at attach time via
  `:code.load_binary/3` (see `Beamcore.Remote.Injector`). The target node does
  not have BeamCore's code loaded, so this module:

    * has **no `Beamcore.*` dependencies** — it must load and run standalone;
    * returns a **fully serializable** map (only binaries, atoms and integers) so
      the result survives the trip back across the distribution channel even when
      the eval raised a project-defined exception whose module the agent node has
      never loaded. Errors and stacktraces are pre-formatted to strings *here*,
      where the relevant modules exist.

  ## Result contract

  `run/2` always returns a map tagged by `:status`:

    * `%{status: :ok, stdout: binary, result: binary}`
    * `%{status: :error, stdout: binary, kind: atom, error: binary, formatted: binary}`
    * `%{status: :timeout, stdout: binary, timeout_ms: integer}`
    * `%{status: :memory_limit, stdout: binary, bytes: integer}`
    * `%{status: :reduction_limit, stdout: binary, reductions: integer}`
    * `%{status: :crash, stdout: binary, reason: binary}`

  The caller (`Beamcore.Remote`) maps these onto the same shapes
  `Beamcore.Agent.Tools.Eeva` already formats for the model.
  """

  # Bump when the runner's behaviour or result contract changes, so the injector
  # re-pushes a stale copy onto a node that still has an old version loaded.
  @version 1

  @sample_interval_ms 20

  @default_timeout_ms 180_000
  @default_max_memory_bytes 256 * 1024 * 1024
  @default_max_reductions 40_000_000
  @default_max_output_bytes 256_000
  @default_max_result_bytes 128_000

  @doc "Version of the runner contract; used by the injector to detect staleness."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Evaluate `quoted` under the given resource `limits`, returning a serializable
  result map (see the moduledoc for the contract).

  `limits` keys (all optional, sensible defaults applied):
  `:timeout_ms`, `:max_memory_bytes`, `:max_reductions`, `:max_output_bytes`,
  `:max_result_bytes`.
  """
  @spec run(Macro.t(), map()) :: map()
  def run(quoted, limits \\ %{}) when is_map(limits) do
    timeout_ms = Map.get(limits, :timeout_ms, @default_timeout_ms)
    max_memory_bytes = Map.get(limits, :max_memory_bytes, @default_max_memory_bytes)
    max_reductions = Map.get(limits, :max_reductions, @default_max_reductions)
    max_output_bytes = Map.get(limits, :max_output_bytes, @default_max_output_bytes)
    max_result_bytes = Map.get(limits, :max_result_bytes, @default_max_result_bytes)

    parent = self()
    {:ok, io} = StringIO.open("")

    {pid, ref} =
      spawn_monitor(fn ->
        configure_heap_limit(max_memory_bytes)
        Process.group_leader(self(), io)
        send(parent, {__MODULE__, :result, self(), evaluate(quoted, max_result_bytes)})
      end)

    classification = await(pid, ref, timeout_ms, max_reductions, max_memory_bytes)
    stdout = capture(io, max_output_bytes)
    finalize(classification, stdout)
  end

  # --- evaluation (runs in the spawned eval process) ---

  defp evaluate(quoted, max_result_bytes) do
    {value, diagnostics} =
      Code.with_diagnostics(fn ->
        {evaluated, _binding} = Code.eval_quoted(quoted, [], file: "eeva", line: 1)
        if is_function(evaluated, 0), do: evaluated.(), else: evaluated
      end)

    {:ok, inspect_result(value, max_result_bytes), format_diagnostics(diagnostics)}
  catch
    kind, error ->
      {:error, kind, safe_inspect(error), Exception.format(kind, error, __STACKTRACE__)}
  end

  # --- supervision of the eval process (runs in the caller) ---

  defp await(pid, ref, timeout_ms, max_reductions, max_memory_bytes) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    loop(pid, ref, deadline, timeout_ms, max_reductions, max_memory_bytes)
  end

  defp loop(pid, ref, deadline, timeout_ms, max_reductions, max_memory_bytes) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill(pid, ref)
      {:timeout, timeout_ms}
    else
      receive do
        {__MODULE__, :result, ^pid, outcome} ->
          Process.demonitor(ref, [:flush])
          {:done, outcome}

        {:DOWN, ^ref, :process, ^pid, reason} ->
          down_reason(reason, max_memory_bytes)
      after
        min(@sample_interval_ms, remaining) ->
          case sample(pid, max_reductions, max_memory_bytes) do
            :ok ->
              loop(pid, ref, deadline, timeout_ms, max_reductions, max_memory_bytes)

            {:exceeded, classification} ->
              kill(pid, ref)
              classification
          end
      end
    end
  end

  defp sample(pid, max_reductions, max_memory_bytes) do
    case Process.info(pid, [:reductions, :memory]) do
      nil ->
        :ok

      info ->
        reductions = Keyword.get(info, :reductions, 0)
        memory = Keyword.get(info, :memory, 0)

        cond do
          memory > max_memory_bytes -> {:exceeded, {:memory_limit, memory}}
          reductions > max_reductions -> {:exceeded, {:reduction_limit, reductions}}
          true -> :ok
        end
    end
  end

  # A heap-size kill surfaces as a DOWN with a :killed-ish reason; treat any
  # abnormal exit that isn't our explicit result as a crash, except map the
  # max_heap_size kill to the memory-limit classification.
  defp down_reason(:killed, max_memory_bytes), do: {:memory_limit, max_memory_bytes}
  defp down_reason({:max_heap_size, _}, max_memory_bytes), do: {:memory_limit, max_memory_bytes}
  defp down_reason(reason, _max_memory_bytes), do: {:crash, safe_inspect(reason)}

  defp kill(pid, ref) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    :ok
  end

  # --- result assembly ---

  defp finalize({:done, {:ok, result, diagnostics}}, stdout) do
    %{status: :ok, stdout: merge(stdout, diagnostics), result: result}
  end

  defp finalize({:done, {:error, kind, error, formatted}}, stdout) do
    %{status: :error, stdout: stdout, kind: kind, error: error, formatted: formatted}
  end

  defp finalize({:timeout, timeout_ms}, stdout) do
    %{status: :timeout, stdout: stdout, timeout_ms: timeout_ms}
  end

  defp finalize({:memory_limit, bytes}, stdout) do
    %{status: :memory_limit, stdout: stdout, bytes: bytes}
  end

  defp finalize({:reduction_limit, reductions}, stdout) do
    %{status: :reduction_limit, stdout: stdout, reductions: reductions}
  end

  defp finalize({:crash, reason}, stdout) do
    %{status: :crash, stdout: stdout, reason: reason}
  end

  # --- helpers ---

  defp configure_heap_limit(max_memory_bytes) do
    word_size = :erlang.system_info(:wordsize)
    max_words = max(div(max_memory_bytes, word_size), 1_024)
    Process.flag(:max_heap_size, %{size: max_words, kill: true})
  end

  defp capture(io, max_output_bytes) do
    {_input, output} = StringIO.contents(io)
    StringIO.close(io)
    limit_binary(output, max_output_bytes)
  end

  defp merge(stdout, ""), do: stdout
  defp merge("", diagnostics), do: diagnostics
  defp merge(stdout, diagnostics), do: stdout <> "\n" <> diagnostics

  defp format_diagnostics([]), do: ""

  defp format_diagnostics(diagnostics) do
    diagnostics
    |> Enum.map(fn diag ->
      severity = Map.get(diag, :severity, :warning)
      message = Map.get(diag, :message, "")

      position =
        case Map.get(diag, :position) do
          line when is_integer(line) -> "eeva:#{line}: "
          {line, col} -> "eeva:#{line}:#{col}: "
          _ -> ""
        end

      "#{position}#{severity}: #{message}"
    end)
    |> Enum.join("\n")
  end

  defp inspect_result(value, max_result_bytes) do
    value
    |> inspect(pretty: true, limit: 100, printable_limit: max_result_bytes)
    |> limit_binary(max_result_bytes)
  end

  defp safe_inspect(term), do: limit_binary(inspect(term), @default_max_result_bytes)

  defp limit_binary(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp limit_binary(binary, max_bytes) do
    suffix = "\n...[truncated]"
    kept = max(max_bytes - byte_size(suffix), 0)
    safe_prefix(binary, kept) <> suffix
  end

  defp safe_prefix(binary, max_bytes) do
    candidate = binary_part(binary, 0, min(byte_size(binary), max_bytes))

    if String.valid?(candidate) do
      candidate
    else
      safe_prefix(candidate, max(byte_size(candidate) - 1, 0))
    end
  end
end
