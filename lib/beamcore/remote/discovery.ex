defmodule Beamcore.Remote.Discovery do
  @moduledoc """
  Finds candidate project nodes via EPMD and resolves user-supplied names.

  Candidates are the locally registered nodes that aren't BeamCore's own
  agent/memory nodes. A project must be started as a **named** node
  (`iex --sname myapp -S mix`) to be attachable and to show up here.
  """

  alias Beamcore.Mesh.NodeNaming

  @doc """
  Local project-node candidates as full node names, excluding BeamCore's own
  nodes and this node. Empty when distribution isn't running.
  """
  @spec candidates() :: [node()]
  def candidates do
    case :erl_epmd.names() do
      {:ok, names} ->
        host = local_host()

        names
        |> Enum.map(fn {name, _port} -> List.to_string(name) end)
        |> Enum.reject(&own_node?/1)
        |> Enum.map(&String.to_atom("#{&1}@#{host}"))
        |> Enum.reject(&(&1 == Node.self()))

      _ ->
        []
    end
  end

  @doc """
  Resolve a user-supplied target to a node name.

  A bare name gets this agent's own host appended (`myapp` -> `myapp@host`); a
  fully-qualified `name@host` is used as-is.
  """
  @spec resolve(binary()) :: node()
  def resolve(name) when is_binary(name) do
    case String.trim(name) do
      "" -> :nonode@nohost
      trimmed -> to_node(trimmed)
    end
  end

  defp to_node(name) do
    if String.contains?(name, "@") do
      String.to_atom(name)
    else
      String.to_atom("#{name}@#{local_host()}")
    end
  end

  defp own_node?(name), do: String.starts_with?(name, NodeNaming.name_prefix())

  defp local_host do
    case Node.self() do
      :nonode@nohost -> List.to_string(elem(:inet.gethostname(), 1))
      self -> self |> Atom.to_string() |> String.split("@", parts: 2) |> List.last()
    end
  end
end
