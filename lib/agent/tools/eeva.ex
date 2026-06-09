defmodule Beamcore.Agent.Tools.Eeva do
  @moduledoc """
  Executes Elixir code under an isolated, temporary supervisor, capturing stdout/stderr and returning exit status.

  Before execution the code is emitted as a `:eeva_preview` runtime event so the
  TUI can display it for the operator to inspect. Execution is hard-capped at
  `@timeout_ms` (1 000 ms) to keep the harness responsive.

  On failure the result includes structured diagnostics: the original exception
  message, its module, a formatted stacktrace, and a human-readable hint so the
  calling model can self-correct.
  """

  @timeout_ms 1_000

  def name, do: "eeva"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description:
          "Executes an Elixir code string under an isolated supervisor. " <>
            "The code is shown in the TUI before execution. " <>
            "Hard timeout: #{@timeout_ms}ms. Returns stdout, exit code, and diagnostics on failure.",
        parameters: %{
          type: "object",
          properties: %{
            code: %{
              type: "string",
              description: "The Elixir code to evaluate and execute."
            }
          },
          required: ["code"]
        }
      }
    }
  end

  def execute(params) do
    code = Map.get(params, "code")

    cond do
      is_nil(code) or String.trim(code) == "" ->
        error_result("No code provided")

      true ->
        emit_preview(code)
        run_supervised(code)
    end
  end

  # ---------------------------------------------------------------------------
  # TUI preview
  # ---------------------------------------------------------------------------

  defp emit_preview(code) do
    case Process.get(:event_handler) do
      handler when is_function(handler, 1) ->
        handler.({:eeva_preview, code})

      _ ->
        # Fallback: walk $ancestors looking for a TUI-connected Agent state.
        case find_tui_and_parent() do
          {parent_pid, tui_pid} when is_pid(parent_pid) and is_pid(tui_pid) ->
            send(tui_pid, {:runtime_event, parent_pid, {:eeva_preview, code}})

          _ ->
            :ok
        end
    end
  end

  defp find_tui_and_parent do
    (Process.get(:"$ancestors") || [])
    |> Enum.find_value({nil, nil}, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          case Agent.get(pid, & &1, 100) do
            %{tui_pid: tui_pid} when is_pid(tui_pid) -> {pid, tui_pid}
            _ -> nil
          end
        catch
          _, _ -> nil
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Supervised execution
  # ---------------------------------------------------------------------------

  defp run_supervised(code) do
    task_fun = fn ->
      {:ok, io} = StringIO.open("")
      Process.group_leader(self(), io)

      try do
        {result, _bindings} = Code.eval_string(code)
        IO.puts("Returned: #{inspect(result)}")
        {:ok, {_in, output}} = StringIO.close(io)
        {:ok, output}
      catch
        kind, error ->
          stacktrace = __STACKTRACE__
          IO.puts("Error: #{Exception.format(kind, error, stacktrace)}")
          {:ok, {_in, output}} = StringIO.close(io)
          {:error, kind, error, stacktrace, output}
      end
    end

    {:ok, sup} = Task.Supervisor.start_link()
    task = Task.Supervisor.async_nolink(sup, task_fun)

    result =
      case Task.yield(task, @timeout_ms) do
        {:ok, {:ok, output}} ->
          success_result(output, code)

        {:ok, {:error, kind, error, stacktrace, output}} ->
          diagnostics = build_diagnostics(kind, error, stacktrace, code)
          failure_result(output, diagnostics, code)

        {:exit, {:crash, {:error, error}, output}} when is_binary(output) ->
          diagnostics = build_diagnostics(:error, error, [], code)
          failure_result(output, diagnostics, code)

        {:exit, reason} ->
          output = extract_output(reason)
          diagnostics = build_exit_diagnostics(reason, code)
          failure_result(output, diagnostics, code)

        nil ->
          Task.shutdown(task, :brutal_kill)
          timeout_result(code)
      end

    Supervisor.stop(sup)
    result
  end

  # ---------------------------------------------------------------------------
  # Diagnostics builders
  # ---------------------------------------------------------------------------

  defp build_diagnostics(kind, raw_error, stacktrace, code) do
    formatted_error = Exception.format(kind, raw_error, stacktrace)

    # Normalize Erlang error terms (e.g. {:badkey, :b}) into Elixir structs (%KeyError{}).
    error = Exception.normalize(kind, raw_error, stacktrace)

    error_module =
      case error do
        %{__struct__: mod} -> inspect(mod)
        _ -> inspect(kind)
      end

    error_message =
      case error do
        %{__struct__: _} -> Exception.message(error)
        _ -> inspect(raw_error)
      end

    formatted_trace =
      case stacktrace do
        [] ->
          "(no stacktrace available)"

        trace ->
          trace
          |> Enum.take(8)
          |> Exception.format_stacktrace()
      end

    hint = diagnose_hint(kind, error, code)

    %{
      "summary" => "Execution failed: #{compact(error_message, 120)}",
      "error_type" => error_module,
      "error_message" => error_message,
      "formatted" => formatted_error,
      "stacktrace" => formatted_trace,
      "hint" => hint
    }
  end

  defp build_exit_diagnostics(reason, _code) do
    %{
      "summary" => "Process exited: #{compact(inspect(reason), 120)}",
      "error_type" => "exit",
      "error_message" => inspect(reason),
      "formatted" => inspect(reason, pretty: true),
      "stacktrace" => "(process exited — no stacktrace)",
      "hint" =>
        "The evaluated code caused the process to exit abnormally. Check for calls to System.halt/1, exit/1, or linked process crashes."
    }
  end

  defp diagnose_hint(:error, %CompileError{description: desc}, _code) do
    "Compilation failed: #{desc}. Check syntax, missing end/do blocks, or undefined variables."
  end

  defp diagnose_hint(:error, %TokenMissingError{} = err, _code) do
    "Syntax error: #{Exception.message(err)}. Check for missing end/do blocks or closing delimiters."
  end

  defp diagnose_hint(:error, %SyntaxError{} = err, _code) do
    "Syntax error: #{Exception.message(err)}. Check for typos, mismatched brackets, or invalid tokens."
  end

  defp diagnose_hint(
         :error,
         %UndefinedFunctionError{module: mod, function: fun, arity: arity},
         _code
       ) do
    "#{inspect(mod)}.#{fun}/#{arity} is not defined. Verify the module is loaded and the function exists with the correct arity."
  end

  defp diagnose_hint(:error, %ArgumentError{message: msg}, _code) do
    "Bad argument: #{msg}. Check the types passed to the function."
  end

  defp diagnose_hint(:error, %RuntimeError{message: msg}, _code) do
    "Runtime error: #{msg}."
  end

  defp diagnose_hint(:error, %FunctionClauseError{module: mod, function: fun}, _code) do
    "No clause in #{inspect(mod)}.#{fun}/? matched the given arguments. Verify the argument shape."
  end

  defp diagnose_hint(:error, %MatchError{term: term}, _code) do
    "Pattern match failed on: #{compact(inspect(term), 100)}. The right-hand side did not match the left-hand pattern."
  end

  defp diagnose_hint(:error, %KeyError{key: key, term: term}, _code) do
    "Key #{inspect(key)} not found in #{compact(inspect(term), 80)}."
  end

  defp diagnose_hint(:throw, value, _code) do
    "Code threw: #{compact(inspect(value), 100)}. Use try/catch if this is expected."
  end

  defp diagnose_hint(_kind, _error, _code) do
    "Review the stacktrace above and verify that all modules, functions, and arguments are correct."
  end

  # ---------------------------------------------------------------------------
  # Result formatters
  # ---------------------------------------------------------------------------

  defp success_result(output, code) do
    %{
      "ok" => true,
      "tool" => name(),
      "exit_code" => 0,
      "stdout" => output,
      "stderr" => "",
      "code" => code,
      "summary" => "Elixir code executed successfully."
    }
    |> Jason.encode!()
  end

  defp failure_result(output, %{} = diagnostics, code) do
    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => 1,
      "stdout" => output,
      "stderr" => "",
      "code" => code,
      "summary" => diagnostics["summary"],
      "diagnostics" => diagnostics
    }
    |> Jason.encode!()
  end

  defp timeout_result(code) do
    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => 1,
      "stdout" => "",
      "stderr" => "",
      "code" => code,
      "summary" => "Execution timed out after #{@timeout_ms}ms.",
      "diagnostics" => %{
        "summary" => "Execution timed out after #{@timeout_ms}ms.",
        "error_type" => "timeout",
        "error_message" => "The code did not complete within #{@timeout_ms}ms.",
        "formatted" => "Timeout: code exceeded the #{@timeout_ms}ms execution limit.",
        "stacktrace" => "(killed — no stacktrace)",
        "hint" =>
          "The code took longer than #{@timeout_ms}ms. " <>
            "Reduce the work (e.g., limit file reads, avoid network calls with long timeouts, avoid Process.sleep)."
      }
    }
    |> Jason.encode!()
  end

  defp error_result(reason) do
    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => "",
      "code" => "",
      "summary" => reason
    }
    |> Jason.encode!()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp extract_output({_, _, output}) when is_binary(output), do: output
  defp extract_output(_), do: ""

  defp compact(text, limit) when byte_size(text) <= limit, do: text
  defp compact(text, limit), do: String.slice(text, 0, max(limit - 3, 0)) <> "..."
end
