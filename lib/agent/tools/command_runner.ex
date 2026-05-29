defmodule Beamcore.Agent.Tools.CommandRunner do
  @moduledoc """
  Internal helper for allowlisted developer command tools.

  This is intentionally not a user-facing shell tool. Callers provide an
  executable and argv list that have already been selected from a fixed allowlist.
  """

  alias Beamcore.Agent.Tools.PathSafety

  @default_timeout 120_000
  @default_max_output 10_000
  @default_tail_lines 40

  def run(tool, command, executable, args, opts \\ [])
      when is_binary(tool) and is_binary(command) and is_binary(executable) and is_list(args) do
    workdir = Keyword.get(opts, :workdir, ".")

    with {:ok, safe_workdir} <- PathSafety.resolve(workdir) do
      do_run(tool, command, executable, args, safe_workdir, opts)
    else
      {:error, reason} ->
        error_result(tool, command, reason)
    end
  end

  def disallowed(tool, command, allowed) do
    %{
      "ok" => false,
      "tool" => tool,
      "command" => command,
      "args" => [],
      "workdir" => ".",
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => "",
      "output_tail" => "",
      "output_tail_lines" => 0,
      "truncated" => false,
      "summary" => "Disallowed #{tool} command '#{command}'. Allowed: #{Enum.join(allowed, ", ")}"
    }
  end

  def encode(result), do: Jason.encode!(result)

  def split_args(nil), do: []
  def split_args(""), do: []

  def split_args(args) when is_binary(args) do
    args
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  def split_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  def split_args(_args), do: []

  defp do_run(tool, command, executable, args, safe_workdir, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    env = Keyword.get(opts, :env, [])

    run_opts = [
      cd: safe_workdir,
      stderr_to_stdout: true,
      env: env
    ]

    # DEBUG: Log the runner and run_opts to see what's being passed
    runner_func = runner(tool)

    started = System.monotonic_time(:millisecond)

    try do
      task = Task.async(fn ->
        runner_func.(executable, args, run_opts)
      end)

      Process.unlink(task.pid)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, exit_code}} ->
          duration = System.monotonic_time(:millisecond) - started
          result(tool, command, executable, args, safe_workdir, output, exit_code, duration, opts)

        nil ->
          error_result(
            tool,
            command,
            "Command timed out after #{timeout}ms: #{executable} #{Enum.join(args, " ")}"
          )

        {:exit, reason} ->
          error_result(
            tool,
            command,
            "Unexpected execution failure: #{inspect(reason)}"
          )
      end
    rescue
      error in ErlangError ->
        error_result(
          tool,
          command,
          "OS error executing #{executable}: #{inspect(error.original)}"
        )

      error ->
        error_result(tool, command, "Unexpected execution failure: #{Exception.message(error)}")
    end
  end

  defp result(tool, command, executable, args, safe_workdir, output, exit_code, duration, opts) do
    output = to_string(output)
    max_output = Keyword.get(opts, :max_output, @default_max_output)
    tail_lines = Keyword.get(opts, :tail_lines, @default_tail_lines)
    truncated_output = truncate(output, max_output)
    diagnostic = output_diagnostic(truncated_output, tail_lines)
    ok = exit_code == 0

    Map.merge(
      %{
        "ok" => ok,
        "tool" => tool,
        "command" => command,
        "executable" => executable,
        "args" => args,
        "workdir" => Path.relative_to(safe_workdir, PathSafety.workspace_root()),
        "exit_code" => exit_code,
        "duration_ms" => duration,
        "stdout" => truncated_output,
        "stderr" => "",
        "summary" => summary(tool, command, ok, exit_code),
        "classification" => Keyword.get(opts, :classification, [])
      },
      diagnostic
    )
  end

  defp error_result(tool, command, reason) do
    %{
      "ok" => false,
      "tool" => tool,
      "command" => command,
      "args" => [],
      "workdir" => ".",
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => "",
      "output_tail" => "",
      "output_tail_lines" => 0,
      "truncated" => false,
      "summary" => reason
    }
  end

  defp summary(tool, command, true, _exit_code),
    do: "#{tool} #{command} completed successfully."

  defp summary(tool, command, false, exit_code),
    do: "#{tool} #{command} failed with exit code #{exit_code}. See output_tail for diagnostics."

  defp output_diagnostic(output, tail_lines) do
    lines = output_lines(output)
    tail = Enum.take(lines, -tail_lines)

    %{
      "output_tail" => Enum.join(tail, "\n"),
      "output_tail_lines" => length(tail),
      "truncated" => length(lines) > tail_lines
    }
  end

  defp output_lines(""), do: []
  defp output_lines(output), do: String.split(output, "\n")

  defp truncate(output, max) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end

  defp runner(tool) do
    Application.get_env(:agent, :"#{tool}_tool_runner") ||
      Application.get_env(:agent, :command_runner) ||
      (&System.cmd/3)
  end
end
