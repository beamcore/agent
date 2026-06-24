defmodule Beamcore.Agent.Tools.Eeva.Sandbox do
  @moduledoc """
  Parses, validates, and instruments model-authored Elixir for supervised Eeva execution.

  The model still writes ordinary Elixir. This module keeps parse-time work
  bounded so malformed or extremely large programs fail cleanly before they
  reach the supervised worker.

  ## System.cmd instrumentation

  The instrument_system_cmd/1 AST rewrite is not a security boundary.
  It exists because language models frequently hallucinate options that
  System.cmd/3 does not accept (:timeout, :verbose, :capture, etc.).
  Native System.cmd raises ArgumentError on unknown options, so
  uninstrumented model-generated code would crash very often without it.

  The rewrite silently rewrites System.cmd/2,3 to
  Beamcore.Agent.Tools.Eeva.system_cmd/2,3, which strips unknown options
  before forwarding to the real System.cmd. This is a compatibility shim
  that makes LLM-generated code robust, not a sandbox that restricts
  capabilities.

  Note: other OS-execution paths (:os.cmd, System.shell, etc.) are not
  rewritten because models usually dont use it. Eeva is a
  full-capability tool for trusted users.
  """

  alias Beamcore.Agent.Tools.Eeva.AtomBudget

  @type prepared :: %{quoted: Macro.t(), node_count: non_neg_integer()}

  @spec prepare(binary(), keyword()) :: {:ok, prepared()} | {:error, binary()}
  def prepare(code, opts \\ [])

  def prepare(code, opts) when is_binary(code) and is_list(opts) do
    max_code_bytes = Keyword.get(opts, :max_code_bytes, 64_000)
    max_ast_nodes = Keyword.get(opts, :max_ast_nodes, 12_000)

    cond do
      byte_size(code) > max_code_bytes ->
        {:error, "Eeva code exceeds the #{max_code_bytes}-byte limit."}

      true ->
        with :ok <- AtomBudget.admit(code),
             {:ok, quoted} <- parse(code),
             quoted <- instrument_system_cmd(quoted),
             {:ok, node_count} <- count_nodes(quoted, max_ast_nodes),
             {:ok, quoted} do
          {:ok, %{quoted: quoted, node_count: node_count}}
        end
    end
  end

  def prepare(_code, _opts), do: {:error, "Eeva code must be a string."}

  defp parse(code), do: parse(code, 8)

  defp parse(code, retries_left) do
    case Code.string_to_quoted(code, file: "eeva", line: 1, existing_atoms_only: true) do
      {:ok, quoted} ->
        {:ok, quoted}

      {:error, reason} ->
        maybe_retry_unsafe_atom_parse(code, retries_left, reason)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp maybe_retry_unsafe_atom_parse(code, retries_left, reason) when retries_left > 0 do
    with {:ok, atom_name} <- unsafe_atom_name(reason),
         :ok <- AtomBudget.admit_identifiers([atom_name]) do
      parse(code, retries_left - 1)
    else
      _ -> {:error, format_parse_error(reason)}
    end
  end

  defp maybe_retry_unsafe_atom_parse(_code, _retries_left, reason),
    do: {:error, format_parse_error(reason)}

  defp instrument_system_cmd(quoted) do
    Macro.postwalk(quoted, fn
      {{:., meta, [{:__aliases__, alias_meta, [:System]}, :cmd]}, call_meta, args}
      when length(args) in [2, 3] ->
        {{:., meta,
          [{:__aliases__, alias_meta, [:Beamcore, :Agent, :Tools, :Eeva]}, :system_cmd]},
         call_meta, args}

      node ->
        node
    end)
  end

  defp unsafe_atom_name({_location, message, token}) do
    text = to_string(message) <> to_string(token)

    if String.contains?(text, "unsafe atom does not exist") do
      token
      |> to_string()
      |> String.trim()
      |> String.trim_leading(":")
      |> String.trim(~s("))
      |> case do
        "" -> :error
        atom_name -> {:ok, atom_name}
      end
    else
      :error
    end
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
    line = Keyword.get(location, :line, 1)
    "Elixir parse error on line #{line}: #{to_string(message)}#{to_string(token)}"
  end
end
