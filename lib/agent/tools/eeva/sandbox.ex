defmodule Beamcore.Agent.Tools.Eeva.Sandbox do
  @moduledoc """
  Parses, validates, and instruments model-authored Elixir for supervised Eeva execution.

  The model still writes ordinary Elixir. Policy enforcement is an execution
  boundary: obvious violations are rejected during AST preflight and real
  computed paths/commands are checked immediately before their side effects.
  """

  alias Beamcore.Agent.Tools.Eeva.{AtomBudget, Policy}

  @type prepared :: %{quoted: Macro.t(), node_count: non_neg_integer()}

  @spec prepare(binary(), map(), keyword()) :: {:ok, prepared()} | {:error, binary()}
  def prepare(code, policy, opts \\ [])

  def prepare(code, policy, opts) when is_binary(code) and is_map(policy) do
    max_code_bytes = Keyword.get(opts, :max_code_bytes, 64_000)
    max_ast_nodes = Keyword.get(opts, :max_ast_nodes, 12_000)

    cond do
      byte_size(code) > max_code_bytes ->
        {:error, "Eeva code exceeds the #{max_code_bytes}-byte limit."}

      true ->
        with :ok <- AtomBudget.admit(code),
             {:ok, quoted} <- parse(code),
             {:ok, node_count} <- count_nodes(quoted, max_ast_nodes),
             {:ok, instrumented} <- Policy.prepare(quoted, policy) do
          {:ok, %{quoted: instrumented, node_count: node_count}}
        end
    end
  end

  def prepare(_code, _policy, _opts), do: {:error, "Eeva code must be a string."}

  defp parse(code) do
    case Code.string_to_quoted(code, file: "eeva", line: 1, existing_atoms_only: true) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, reason} -> {:error, format_parse_error(reason)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp count_nodes(quoted, max_ast_nodes) do
    {_quoted, count} = Macro.prewalk(quoted, 0, fn node, count -> {node, count + 1} end)

    if count > max_ast_nodes do
      {:error, "Eeva code exceeds the #{max_ast_nodes}-node AST limit."}
    else
      {:ok, count}
    end
  end

  defp format_parse_error({location, message, token}) do
    line = if is_list(location), do: Keyword.get(location, :line, 1), else: location
    "Elixir parse error on line #{line}: #{to_string(message)}#{to_string(token)}"
  end

  defp format_parse_error(reason), do: inspect(reason)
end
