# Eeva: run arbitrary Elixir code via an OTP-supervised worker.

defmodule Beamcore.Agent.Tools.Eeva do
  @moduledoc """
  The single model-facing execution tool in BeamCore.

  Eeva accepts ordinary Elixir code, starts an OTP-supervised execution worker,
  captures stdout and the returned value. It intentionally does not expose
  prepared read/write/search/git/test sub-tools: the model writes the Elixir
  program it needs, using the language and runtime directly.
  """

  alias Beamcore.Agent.Tools.Eeva.{Sandbox, Supervisor, Worker}
  alias Beamcore.Agent.Tools.PathInput
  alias Beamcore.Remote
  alias Beamcore.Remote.Session

  @default_timeout_ms 180_000
  @default_max_memory_bytes 256 * 1024 * 1024
  @default_max_reductions 40_000_000
  @default_max_output_bytes 256_000
  @default_max_result_bytes 128_000
  @default_max_code_bytes 128_000
  @default_max_ast_nodes 24_000
  @max_preview_bytes 16_000
  @max_failure_message_chars 240
  @max_output_lines 200
  @max_single_line_chars 1000

  def name, do: "eeva"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: """
        Execute arbitrary Elixir code. This universal tool can inspect and edit files, run direct system commands such as git or mix, parse data, and interact with Beamcore.Memory.
        The runtime captures stdout/stderr and returns structured results.
        For delegating work to other models, use Beamcore.Agent.SubAgent -- spawn a sub-agent with SubAgent.run("task") or offload to cheaper models with SubAgent.run("task", provider: "mistral").
        """,
        parameters: %{
          type: "object",
          properties: %{
            code: %{
              type: "string",
              description:
                "Elixir source code to evaluate. You are not limited to simple commands; write any multi-expression program to achieve your goals. Examples: File.read!(\"README.md\"), System.cmd(\"git\", [\"status\"]). A returned zero-arity function is invoked automatically."
            }
          },
          required: ["code"]
        }
      }
    }
  end

  def execute(params) when is_map(params) do
    code = Map.get(params, "code") || Map.get(params, :code)

    try do
      cond do
        not is_binary(code) or String.trim(code) == "" ->
          encode_error("No code provided", "invalid_request")

        true ->
          code = normalize_code(code)
          emit_preview(preview_code(code))
          prepare_and_execute(code)
      end
    rescue
      error ->
        encode_error(
          "Unexpected Eeva failure: #{Exception.message(error)}",
          "internal_error"
        )
    catch
      kind, reason ->
        encode_error(
          "Unexpected Eeva #{kind}: #{inspect(reason)}",
          "internal_error"
        )
    end
  end

  def execute(_params),
    do: encode_error("Parameters must be an object", "invalid_request")

  @doc false
  def system_cmd(command, args, opts \\ [])

  # Options that native System.cmd/3 actually accepts.
  #
  # This list exists because models frequently hallucinate options that
  # System.cmd does not support (:timeout, :verbose, :capture, :shell, etc.).
  # Native System.cmd raises ArgumentError on any unknown option key, so
  # passing model-generated opts through unfiltered would crash on nearly
  # every call.
  #
  # The Sandbox AST rewrite (instrument_system_cmd/1) rewrites every
  # `System.cmd` call in model-authored code to this wrapper. We then
  # Keyword.take/2 down to only the valid keys, silently dropping the rest.
  # This is a compatibility shim — not a security boundary. The goal is
  # robustness: the model shouldn't need to know System.cmd's exact option
  # API to write working code.
  #
  # NOTE: :into and :lines are intentionally excluded. :into controls
  # return shape and would interfere with our stdout capture. :lines
  # is a line-length hint rarely needed for tool usage. :stderr_to_stdout
  # is force-set to true so the Worker always captures both streams.
  @valid_cmd_opts [:cd, :env, :arg0, :parallelism]

  def system_cmd(command, args, opts) when is_list(args) and is_list(opts) do
    opts =
      opts
      |> Keyword.take(@valid_cmd_opts)
      |> Keyword.put(:stderr_to_stdout, true)

    System.cmd(command, args, opts)
  end

  defp normalize_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> strip_markdown_fence()
  end

  defp strip_markdown_fence(code) do
    lines = String.split(code, "\n")

    case lines do
      [first | rest] ->
        last = List.last(rest)

        if fence_line?(first) and fence_line?(last) do
          rest
          |> Enum.drop(-1)
          |> Enum.join("\n")
          |> String.trim()
        else
          code
        end

      _ ->
        code
    end
  end

  defp fence_line?(line) when is_binary(line) do
    line
    |> String.trim()
    |> String.starts_with?("```")
  end

  defp fence_line?(_), do: false

  defp prepare_and_execute(code) do
    case Sandbox.prepare(code,
           max_code_bytes: limit(:max_code_bytes, @default_max_code_bytes),
           max_ast_nodes: limit(:max_ast_nodes, @default_max_ast_nodes)
         ) do
      {:ok, prepared} ->
        execute_prepared(code, prepared)

      {:error, reason} ->
        encode_error(reason, "execution_guard")
    end
  end

  defp execute_prepared(code, prepared) do
    result =
      case Session.target() do
        :local ->
          run(prepared.quoted, self(), PathInput.workspace_root())

        {:attached, node} ->
          Remote.run(node, prepared.quoted, remote_limits())
      end

    format_result(result, code, prepared)
  end

  defp remote_limits do
    %{
      timeout_ms: limit(:timeout_ms, @default_timeout_ms),
      max_memory_bytes: limit(:max_memory_bytes, @default_max_memory_bytes),
      max_reductions: limit(:max_reductions, @default_max_reductions),
      max_output_bytes: limit(:max_output_bytes, @default_max_output_bytes),
      max_result_bytes: limit(:max_result_bytes, @default_max_result_bytes)
    }
  end

  defp run(quoted, owner, workspace_root) do
    opts = [
      quoted: quoted,
      owner: owner,
      workspace_root: workspace_root,
      timeout_ms: limit(:timeout_ms, @default_timeout_ms),
      max_memory_bytes: limit(:max_memory_bytes, @default_max_memory_bytes),
      max_reductions: limit(:max_reductions, @default_max_reductions),
      max_output_bytes: limit(:max_output_bytes, @default_max_output_bytes),
      max_result_bytes: limit(:max_result_bytes, @default_max_result_bytes)
    ]

    with {:ok, pid} <- Supervisor.start_execution(opts) do
      Worker.await(pid)
    else
      {:error, reason} -> {:error, :supervisor_start, reason}
    end
  end

  defp format_result({:ok, %{status: :ok} = result}, _code, prepared) do
    {stdout, dropped} = truncate_output(result.output)

    %{
      "ok" => true,
      "tool" => name(),
      "exit_code" => 0,
      "stdout" => stdout,
      "stderr" => "",
      "result" => result.result,
      "ast_nodes" => prepared.node_count,
      "summary" => append_truncation("Eeva completed successfully.", dropped)
    }
    |> Jason.encode!()
  end

  defp format_result({:ok, %{status: :error} = result}, _code, prepared) do
    {stdout, dropped} = truncate_output(result.output)

    # Build the hint-enriched message once; use it for both the model-facing
    # summary and the TUI failure event so models get actionable guidance.
    error_message = failure_message(result.kind, result.error, result.stacktrace)

    summary =
      append_truncation(
        recoverable_summary("Eeva program raised #{error_message}."),
        dropped
      )

    emit_failure(error_message)

    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => 1,
      "stdout" => stdout,
      "stderr" => Exception.format(result.kind, result.error, result.stacktrace),
      "result" => nil,
      "ast_nodes" => prepared.node_count,
      "recoverable" => true,
      "session_active" => true,
      "next_step" => recoverable_next_step(),
      "summary" => summary
    }
    |> Jason.encode!()
  end

  # Remote eval raised. stderr/message are already formatted to strings on the
  # project node (where the exception's module exists), so we use them directly
  # rather than re-deriving via Exception.format/3.
  defp format_result(
         {:remote_error, %{stdout: stdout, stderr: stderr, message: message}},
         _code,
         prepared
       ) do
    {out, dropped} = truncate_output(stdout)
    summary = append_truncation(recoverable_summary("Eeva program raised #{message}."), dropped)

    emit_failure(message)

    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => 1,
      "stdout" => out,
      "stderr" => stderr,
      "result" => nil,
      "ast_nodes" => prepared.node_count,
      "recoverable" => true,
      "session_active" => true,
      "next_step" => recoverable_next_step(),
      "summary" => summary
    }
    |> Jason.encode!()
  end

  defp format_result({:error, kind, reason}, _code, prepared) do
    emit_failure(execution_error_summary(kind, reason))
    summary = recoverable_summary(execution_error_summary(kind, reason))

    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => inspect(reason),
      "result" => nil,
      "ast_nodes" => prepared.node_count,
      "recoverable" => true,
      "session_active" => true,
      "next_step" => recoverable_next_step(),
      "summary" => summary
    }
    |> Jason.encode!()
  end

  # Truncates model-facing stdout so a single Eeva response never overwhelms the
  # model: at most @max_output_lines lines for multi-line output, or
  # @max_single_line_chars characters when the output is a single line. Returns
  # the (possibly truncated) text and a description of what was omitted so the
  # model can align its next action.
  defp truncate_output(output) when is_binary(output) do
    lines = String.split(output, "\n")

    cond do
      length(lines) <= 1 ->
        truncate_single_line(output)

      length(lines) > @max_output_lines ->
        kept = Enum.take(lines, @max_output_lines)
        dropped_lines = length(lines) - @max_output_lines

        notice =
          "\n...[output truncated: #{dropped_lines} more line(s) omitted; " <>
            "showing first #{@max_output_lines} of #{length(lines)} lines]"

        {Enum.join(kept, "\n") <> notice, "#{dropped_lines} line(s)"}

      true ->
        {output, nil}
    end
  end

  defp truncate_output(output), do: {output, nil}

  defp truncate_single_line(output) do
    total = String.length(output)

    if total > @max_single_line_chars do
      dropped_chars = total - @max_single_line_chars

      notice =
        "\n...[output truncated: #{dropped_chars} more character(s) omitted; " <>
          "showing first #{@max_single_line_chars} of #{total} characters]"

      {String.slice(output, 0, @max_single_line_chars) <> notice, "#{dropped_chars} character(s)"}
    else
      {output, nil}
    end
  end

  defp append_truncation(summary, nil), do: summary

  defp append_truncation(summary, dropped),
    do: summary <> " Output was truncated (#{dropped} omitted)."

  defp execution_error_summary(:timeout, timeout),
    do: "Eeva exceeded the #{timeout}ms execution timeout."

  defp execution_error_summary(:memory_limit, bytes),
    do: "Eeva exceeded the memory budget at #{bytes} bytes."

  defp execution_error_summary(:reduction_limit, reductions),
    do: "Eeva exceeded the reduction budget at #{reductions} reductions."

  defp execution_error_summary(kind, reason),
    do: "Eeva execution failed (#{kind}): #{inspect(reason)}"

  defp encode_error(message, classification) do
    emit_failure(message, classification)
    summary = recoverable_summary(message)

    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => message,
      "result" => nil,
      "classification" => classification,
      "recoverable" => true,
      "session_active" => true,
      "next_step" => recoverable_next_step(),
      "summary" => summary
    }
    |> Jason.encode!()
  end

  defp emit_preview(code) do
    case Process.get(:event_handler) do
      handler when is_function(handler, 1) ->
        handler.({:eeva_preview, code})

      _ ->
        :ok
    end
  catch
    _, _ -> :ok
  end

  # Surfaces a single concise failure message to the TUI. Successful executions
  # emit nothing, so the activity log stays quiet unless the model's code
  # actually failed (guard violation, raised exception, timeout, etc.).
  defp emit_failure(message, classification \\ "execution_failed") do
    case Process.get(:event_handler) do
      handler when is_function(handler, 1) ->
        summary = short_failure(message)

        handler.(
          {:execution_stopped,
           %{
             type: :execution_stopped,
             source: :eeva,
             reason: reason_for_classification(classification, summary),
             summary: "Eeva stopped: #{summary}",
             details: %{classification: classification},
             recoverable?: true
           }}
        )

      _ ->
        :ok
    end
  catch
    _, _ -> :ok
  end

  defp reason_for_classification("execution_guard", _message), do: :guard_blocked

  defp reason_for_classification(_classification, message) do
    downcased = String.downcase(to_string(message))

    cond do
      String.contains?(downcased, "timeout") -> :timeout
      String.contains?(downcased, "guard") -> :guard_blocked
      String.contains?(downcased, "blocked") -> :guard_blocked
      String.contains?(downcased, "unavailable") -> :guard_blocked
      String.contains?(downcased, "path") -> :path_blocked
      true -> :execution_failed
    end
  end

  defp short_failure(message) do
    message
    |> to_string()
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("")
    |> String.trim()
    |> String.slice(0, @max_failure_message_chars)
  end

  defp failure_message(kind, error, stacktrace) do
    # Normalize bare atoms like :badarg into proper exception structs so
    # add_common_hint can pattern-match on the struct type.
    normalized = Exception.normalize(kind, error)

    # The formatted exception with stacktrace includes BIF-specific details
    # (e.g. "not an atom" from :erlang.whereis) that the message alone lacks.
    formatted = Exception.format(kind, error, stacktrace)

    message =
      try do
        Exception.message(normalized)
      rescue
        _ -> inspect(error)
      end
      |> add_common_hint(normalized, formatted)

    case kind do
      :error -> message
      _ -> "(#{kind}) #{inspect(error)}"
    end
  end

  defp add_common_hint(message, %Protocol.UndefinedError{protocol: Enumerable, value: value}, _fmt)
       when is_tuple(value) do
    message <>
      ~s| Hint: many File.* functions return {:ok, value}; pattern-match first, for example {:ok, entries} = File.ls(".").|
  end


  # Atom confusion: string passed where atom expected (Process.whereis, GenServer.call, :erlang BIFs, etc.)
  # Uses the *formatted* exception string because bare :badarg atoms normalise to
  # %ArgumentError{message: "argument error"} which lacks the "not an atom" detail.
  defp add_common_hint(message, %ArgumentError{}, formatted) do
    cond do
      String.contains?(formatted, "not an atom") or
        String.contains?(formatted, "not an already existing atom") ->
        message <>
          " Hint: this function requires an atom, not a string." <>
          " For registered processes use Process.whereis(ModuleName)." <>
          " For dynamic module dispatch use Module.concat/1 or Module.safe_concat/1." <>
          " To convert a string to an atom use String.to_atom/1."

      true ->
        message
    end
  end

  # FunctionClauseError from GenServer.whereis/1 when given a non-atom (e.g. a string)
  # Matches via formatted exception because bare :function_clause normalises to
  # %FunctionClauseError{module: nil} — the module/function info is only in the trace.
  defp add_common_hint(message, %FunctionClauseError{}, formatted) do
    if String.contains?(formatted, "GenServer.whereis") do
      message <>
        " Hint: GenServer.call/3 expects an atom (registered name) or a pid, not a string." <>
        " Use Process.whereis(MyModule) to look up a registered process by its atom name."
    else
      message
    end
  end
  defp add_common_hint(message, _error, _fmt), do: message

  defp recoverable_summary(message) do
    "Tool call failed, but the session is still active. #{message} " <>
      recoverable_next_step()
  end

  defp recoverable_next_step,
    do: "Inspect the error, adjust the approach, and retry or choose another path."

  defp preview_code(code) when byte_size(code) <= @max_preview_bytes, do: code

  defp preview_code(code) do
    binary_part(code, 0, @max_preview_bytes) <> "\n# ... preview truncated"
  end

  defp limit(name, default) do
    config_key = :"eeva_#{name}"
    Beamcore.Config.get_setting(config_key, default)
  end
end
