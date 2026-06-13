defmodule Beamcore.Agent.Tools.Eeva.Sandbox do
  @moduledoc """
  Parses, validates, and instruments model-authored Elixir for supervised Eeva execution.

  The model still writes ordinary Elixir. Runtime guards are an execution
  boundary: obvious unsafe operations are rejected during AST preflight and real
  computed paths/commands are checked immediately before their side effects.
  """

  alias Beamcore.Agent.Tools.Eeva.AtomBudget

  @shell_interceptors ~w(sh bash zsh csh ksh dash fish tcsh ash)

  @type prepared :: %{quoted: Macro.t(), node_count: non_neg_integer()}

  @spec prepare(binary(), map(), keyword()) :: {:ok, prepared()} | {:error, binary()}
  def prepare(code, caps, opts \\ [])

  def prepare(code, caps, opts) when is_binary(code) and is_map(caps) do
    max_code_bytes = Keyword.get(opts, :max_code_bytes, 64_000)
    max_ast_nodes = Keyword.get(opts, :max_ast_nodes, 12_000)

    cond do
      byte_size(code) > max_code_bytes ->
        {:error, "Eeva code exceeds the #{max_code_bytes}-byte limit."}

      true ->
        with :ok <- AtomBudget.admit(code),
             {:ok, quoted} <- parse(code),
             :ok <- check_shell_interceptors(quoted),
             {:ok, node_count} <- count_nodes(quoted, max_ast_nodes),
             {:ok, quoted} do
          {:ok, %{quoted: quoted, node_count: node_count}}
        end
    end
  end

  def prepare(_code, _caps, _opts), do: {:error, "Eeva code must be a string."}

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

  # Checks AST for System.cmd calls targeting shell interpreters.
  defp check_shell_interceptors(quoted) do
    Macro.prewalk(quoted, :ok, fn
      node, :ok ->
        if shell_cmd?(node) do
          {:error, "Shell interpreters (sh, bash, zsh, etc.) are not allowed in Eeva. Use direct Elixir functions instead."}
        else
          {node, :ok}
        end

      node, acc ->
        {node, acc}
    end)
    |> case do
      {:error, _} = err -> err
      {_, :ok} -> :ok
    end
  end

  # Matches System.cmd("sh", [...]) style calls with 2 or 3 args
  defp shell_cmd?({{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, [cmd | _]}) when is_binary(cmd) do
    cmd in @shell_interceptors
  end

  defp shell_cmd?(_node), do: false

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
