defmodule Beamcore.Agent.Tools.CommandRunner do
  @moduledoc """
  Internal helper for allowlisted developer command tools.

  This is intentionally not a user-facing shell tool. Callers provide an
  executable and argv list that have already been selected from a fixed allowlist.
  """

  alias Beamcore.Agent.Tools.PathSafety
  alias Beamcore.Agent.FilesystemJournal

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

  def release_env_keys do
    ~w(
      RELEASE_ROOT
      RELEASE_NAME
      RELEASE_VSN
      RELEASE_COOKIE
      RELEASE_MODE
      RELEASE_NODE
      RELEASE_TMP
      RELEASE_VM_ARGS
      RELEASE_REMOTE_VM_ARGS
      RELEASE_DISTRIBUTION
      RELEASE_BOOT_SCRIPT
      RELEASE_BOOT_SCRIPT_CLEAN
      RELEASE_COMMAND
      RELEASE_PROG
      RELEASE_SYS_CONFIG
      BINDIR
      EMU
      PROGNAME
      REL_DIR
      ROOTDIR
      RUNNER_LOG_DIR
      SCRIPT
      ERL_LIBS
    )
  end

  def external_env(overrides \\ []) do
    overrides = Enum.map(overrides, fn {key, value} -> {to_string(key), value} end)
    override_keys = MapSet.new(Enum.map(overrides, &elem(&1, 0)))
    release_root = System.get_env("RELEASE_ROOT")

    base =
      System.get_env()
      |> Enum.reject(fn {key, value} ->
        key in release_env_keys() or MapSet.member?(override_keys, key) or
          release_scoped_erl_libs?(key, value)
      end)
      |> Enum.map(&sanitize_env_value(&1, release_root))

    base ++ overrides ++ Enum.map(release_env_keys(), &{&1, nil})
  end

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
    env = opts |> Keyword.get(:env, []) |> external_env()

    run_opts = [
      cd: safe_workdir,
      stderr_to_stdout: true,
      env: env
    ]

    runner_func = runner(tool)

    started = System.monotonic_time(:millisecond)

    mutation_scope =
      case FilesystemJournal.begin_command_scope(tool, command, safe_workdir, opts) do
        {:ok, scope} -> scope
        {:error, _reason} -> nil
      end

    try do
      task = async_command(fn -> runner_func.(executable, args, run_opts) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, exit_code}} ->
          duration = System.monotonic_time(:millisecond) - started
          changes = complete_command_scope(mutation_scope)

          result(
            tool,
            command,
            executable,
            args,
            safe_workdir,
            output,
            exit_code,
            duration,
            opts,
            changes
          )

        nil ->
          complete_command_scope(mutation_scope)

          error_result(
            tool,
            command,
            "Command timed out after #{timeout}ms: #{executable} #{Enum.join(args, " ")}"
          )

        {:exit, reason} ->
          complete_command_scope(mutation_scope)

          error_result(
            tool,
            command,
            "Unexpected execution failure: #{inspect(reason)}"
          )
      end
    rescue
      error in ErlangError ->
        complete_command_scope(mutation_scope)

        error_result(
          tool,
          command,
          "OS error executing #{executable}: #{inspect(error.original)}"
        )

      error ->
        complete_command_scope(mutation_scope)
        error_result(tool, command, "Unexpected execution failure: #{Exception.message(error)}")
    end
  end

  defp result(
         tool,
         command,
         executable,
         args,
         safe_workdir,
         output,
         exit_code,
         duration,
         opts,
         filesystem_changes
       ) do
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
        "classification" => Keyword.get(opts, :classification, []),
        "filesystem_changes" => filesystem_changes || %{"changed_path_count" => 0}
      },
      diagnostic
    )
  end

  defp complete_command_scope(scope) do
    case FilesystemJournal.complete_command_scope(scope) do
      {:ok, changes} ->
        changes

      {:error, reason} ->
        %{"changed_path_count" => 0, "error" => reason}
    end
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

  defp release_scoped_erl_libs?("ERL_LIBS", value) when is_binary(value) do
    release_root = System.get_env("RELEASE_ROOT")
    is_binary(release_root) and release_root != "" and String.contains?(value, release_root)
  end

  defp release_scoped_erl_libs?(_key, _value), do: false

  defp sanitize_env_value({"PATH", value}, release_root) when is_binary(value) do
    {"PATH", strip_release_path_entries(value, release_root)}
  end

  defp sanitize_env_value(pair, _release_root), do: pair

  defp strip_release_path_entries(path, release_root)
       when is_binary(release_root) and release_root != "" do
    path
    |> String.split(":", trim: true)
    |> Enum.reject(fn entry ->
      entry == release_root or String.starts_with?(entry, release_root <> "/")
    end)
    |> Enum.join(":")
  end

  defp strip_release_path_entries(path, _release_root), do: path

  defp async_command(fun) when is_function(fun, 0) do
    if Process.whereis(Beamcore.Agent.TaskSupervisor) do
      Task.Supervisor.async_nolink(Beamcore.Agent.TaskSupervisor, fun)
    else
      task = Task.async(fun)
      Process.unlink(task.pid)
      task
    end
  end
end
