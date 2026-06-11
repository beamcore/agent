defmodule Beamcore.Agent.SafeCmd do
  @moduledoc """
  Shared helper for safely executing external commands with timeout and error handling.
  """

  @default_timeout 30_000
  @max_output_bytes 1_000_000

  @doc """
  Runs a command only if the executable exists on PATH.
  Returns `{:ok, output, exit_code}` on success, `{:error, reason}` otherwise.

  Options:
    - `:timeout` — max milliseconds before killing the process (default: 30s)
    - All other opts are passed to `System.cmd/3`
  """
  @spec run(binary(), [binary()], keyword()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def run(command, args, opts \\ []) do
    {timeout, cmd_opts} = Keyword.pop(opts, :timeout, @default_timeout)

    case System.find_executable(command) do
      nil ->
        {:error, :enoent}

      _path ->
        run_with_timeout(command, args, cmd_opts, timeout)
    end
  end

  defp run_with_timeout(command, args, cmd_opts, timeout) do
    task =
      Task.async(fn ->
        try do
          {output, exit_code} = System.cmd(command, args, cmd_opts)
          output = truncate_output(output)
          {:ok, output, exit_code}
        rescue
          e in ErlangError -> {:error, e.original}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, "command timed out after #{timeout}ms: #{command} #{Enum.join(args, " ")}"}
    end
  end

  defp truncate_output(output) when byte_size(output) > @max_output_bytes do
    binary_part(output, 0, @max_output_bytes) <> "\n... (output truncated at 1MB)"
  end

  defp truncate_output(output), do: output
end
