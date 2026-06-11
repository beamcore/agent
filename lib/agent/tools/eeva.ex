defmodule Beamcore.Agent.Tools.Eeva do
  @moduledoc """
  The single model-facing execution tool in BeamCore.

  Eeva accepts ordinary Elixir code, starts an OTP-supervised execution worker,
  captures stdout and the returned value, and records workspace changes in the
  reversible filesystem journal. It intentionally does not expose prepared
  read/write/search/git/test sub-tools: the model writes the Elixir program it
  needs, using the language and runtime directly.
  """

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.FilesystemJournal
  alias Beamcore.Agent.Tools.Eeva.{Sandbox, Supervisor, Worker}
  alias Beamcore.Agent.PathSafety

  @default_timeout_ms 30_000
  @default_max_memory_bytes 256 * 1024 * 1024
  @default_max_reductions 40_000_000
  @default_max_output_bytes 256_000
  @default_max_result_bytes 128_000
  @default_max_code_bytes 128_000
  @default_max_ast_nodes 24_000
  @max_preview_bytes 16_000
  @max_output_lines 200
  @max_single_line_chars 1000

  def name, do: "eeva"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description:
          "Execute arbitrary Elixir code. This universal tool provides endless capabilities: write Elixir to read/write files, run system commands (git, mix, etc.), parse data, or interact with Beamcore.Memory. The runtime handles policy checks, side effects, and returns stdout, results, and journaled changes.",
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

  def execute(params),
    do: execute(params, Process.get(:beamcore_tool_policy) || ToolPolicy.default())

  def execute(params, policy) when is_map(params) and is_map(policy) do
    code = Map.get(params, "code") || Map.get(params, :code)

    try do
      cond do
        not is_binary(code) or String.trim(code) == "" ->
          encode_error("No code provided", "invalid_request")

        true ->
          emit_preview(preview_code(code))
          prepare_and_execute(code, policy)
      end
    rescue
      error ->
        encode_error(
          "Unexpected Eeva failure: #{Exception.message(error)}",
          "internal_error",
          code
        )
    catch
      kind, reason ->
        encode_error(
          "Unexpected Eeva #{kind}: #{inspect(reason)}",
          "internal_error",
          code
        )
    end
  end

  def execute(_params, _policy),
    do: encode_error("Parameters must be an object", "invalid_request")

  defp prepare_and_execute(code, policy) do
    case Sandbox.prepare(code, policy,
           max_code_bytes: limit(:max_code_bytes, @default_max_code_bytes),
           max_ast_nodes: limit(:max_ast_nodes, @default_max_ast_nodes)
         ) do
      {:ok, prepared} ->
        execute_prepared(code, prepared, policy)

      {:error, "Policy violation:" <> _rest = reason} ->
        encode_error(reason, "policy_violation", code)

      {:error, reason} ->
        encode_error(reason, "execution_guard", code)
    end
  end

  defp execute_prepared(code, prepared, policy) do
    owner = self()
    filesystem_context = FilesystemJournal.context()
    workspace_root = context_workspace_root(filesystem_context)

    start_position = FilesystemJournal.journal_position(workspace_root)
    result = run(prepared.quoted, policy, owner, workspace_root, filesystem_context)
    filesystem_changes = FilesystemJournal.changes_since(workspace_root, start_position)

    format_result(result, code, prepared, filesystem_changes)
  end

  defp run(quoted, policy, owner, workspace_root, filesystem_context) do
    opts = [
      quoted: quoted,
      owner: owner,
      policy: policy,
      workspace_root: workspace_root,
      filesystem_context: filesystem_context,
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

  defp context_workspace_root(%{workspace_root: root}) when is_binary(root), do: PathSafety.canonical_path(root)
  defp context_workspace_root(_context), do: PathSafety.workspace_root()

  defp format_result({:ok, %{status: :ok} = result}, code, prepared, filesystem_changes) do
    {stdout, dropped} = truncate_output(result.output)

    %{
      "ok" => true,
      "tool" => name(),
      "exit_code" => 0,
      "stdout" => stdout,
      "stderr" => "",
      "result" => result.result,
      "code" => code,
      "ast_nodes" => prepared.node_count,
      "filesystem_changes" => filesystem_changes,
      "summary" => append_truncation(success_summary(filesystem_changes), dropped)
    }
    |> Jason.encode!()
  end

  defp format_result({:ok, %{status: :error} = result}, code, prepared, filesystem_changes) do
    {stdout, dropped} = truncate_output(result.output)

    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => 1,
      "stdout" => stdout,
      "stderr" => Exception.format(result.kind, result.error, result.stacktrace),
      "result" => nil,
      "code" => code,
      "ast_nodes" => prepared.node_count,
      "filesystem_changes" => filesystem_changes,
      "summary" =>
        append_truncation("Eeva program raised #{inspect(result.error)}.", dropped)
    }
    |> Jason.encode!()
  end

  defp format_result({:error, kind, reason}, code, prepared, filesystem_changes) do
    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => inspect(reason),
      "result" => nil,
      "code" => code,
      "ast_nodes" => prepared.node_count,
      "filesystem_changes" => filesystem_changes,
      "summary" => execution_error_summary(kind, reason)
    }
    |> Jason.encode!()
  end

  defp success_summary(%{"changed_path_count" => count}) when is_integer(count) and count > 0,
    do: "Eeva completed and journaled #{count} changed workspace path(s)."

  defp success_summary(_), do: "Eeva completed successfully."

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

  defp encode_error(message, classification, code \\ nil) do
    %{
      "ok" => false,
      "tool" => name(),
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => message,
      "result" => nil,
      "code" => code,
      "classification" => classification,
      "filesystem_changes" => %{"changed_path_count" => 0},
      "summary" => message
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

  defp preview_code(code) when byte_size(code) <= @max_preview_bytes, do: code

  defp preview_code(code) do
    binary_part(code, 0, @max_preview_bytes) <> "\n# ... preview truncated"
  end

  defp limit(name, default) do
    env = "BEAMCORE_EEVA_" <> (name |> Atom.to_string() |> String.upcase())

    case Integer.parse(System.get_env(env, "")) do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end
end
