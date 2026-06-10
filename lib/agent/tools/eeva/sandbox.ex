defmodule Beamcore.Agent.Tools.Eeva.Sandbox do
  @moduledoc """
  Parses model-authored Elixir for OTP-supervised execution.

  Eeva intentionally exposes ordinary Elixir rather than a catalogue of prepared
  capabilities. The model supplies an Elixir program; the runtime supervises the
  process, captures output and result data, and journals workspace changes around
  the execution.

  This module only enforces source-size, identifier-budget, and AST-size limits.
  It does not rewrite File, Path, System, Git, test, math, or process calls into
  bespoke tools.
  """

  alias Beamcore.Agent.Tools.Eeva.AtomBudget

  @type prepared :: %{quoted: Macro.t(), node_count: non_neg_integer()}

  @spec prepare(binary(), keyword()) :: {:ok, prepared()} | {:error, binary()}
  def prepare(code, opts \\ [])

  def prepare(code, opts) when is_binary(code) do
    max_code_bytes = Keyword.get(opts, :max_code_bytes, 64_000)
    max_ast_nodes = Keyword.get(opts, :max_ast_nodes, 12_000)

    cond do
      byte_size(code) > max_code_bytes ->
        {:error, "Eeva code exceeds the #{max_code_bytes}-byte limit."}

      true ->
        with :ok <- AtomBudget.admit(code),
             {:ok, quoted} <- parse(code),
             {:ok, node_count} <- count_nodes(quoted, max_ast_nodes) do
          {:ok, %{quoted: quoted, node_count: node_count}}
        end
    end
  end

  def prepare(_code, _opts), do: {:error, "Eeva code must be a string."}

  defp parse(code) do
    case Code.string_to_quoted(code, file: "eeva", line: 1, existing_atoms_only: true) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, reason} -> {:error, format_parse_error(reason)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp count_nodes(quoted, max_ast_nodes) do
    {_quoted, {count, protected_path?}} =
      Macro.prewalk(quoted, {0, false}, fn node, {count, protected_path?} ->
        protected_path? =
          protected_path? or
            (is_binary(node) and
               (String.contains?(String.downcase(node), ".beamcore/snapshots") or
                  String.contains?(String.downcase(node), ".beamcore/recovery")))

        {node, {count + 1, protected_path?}}
      end)

    cond do
      protected_path? ->
        {:error, "Eeva code cannot access BeamCore internal snapshot or recovery storage."}

      count > max_ast_nodes ->
        {:error, "Eeva code exceeds the #{max_ast_nodes}-node AST limit."}

      true ->
        {:ok, count}
    end
  end

  defp format_parse_error({location, message, token}) do
    line = if is_list(location), do: Keyword.get(location, :line, 1), else: location
    "Elixir parse error on line #{line}: #{to_string(message)}#{to_string(token)}"
  end

  defp format_parse_error(reason), do: inspect(reason)
end
