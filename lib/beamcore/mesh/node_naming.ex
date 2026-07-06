defmodule Beamcore.Mesh.NodeNaming do
  @moduledoc """
  Node naming helper for the Beamcore mesh.

  Sets the distributed node name at application boot if not already started
  via --sname. Uses a short hash of hostname + pid for uniqueness.
  """

  @name_prefix "beamcore"

  @doc """
  Ensures the node is distributed. If not, starts distribution with a
  generated short name. Called from Application.start/2.
  """
  def ensure_distributed! do
    if Node.alive?() do
      :ok
    else
      name = generate_name() |> String.to_atom()
      {:ok, _} = Node.start(name, :shortnames)
      :ok
    end
  end

  @doc "Generates a unique short node name for this instance."
  def generate_name do
    hostname = elem(:inet.gethostname(), 1) |> to_string()

    material =
      hostname <>
        "-" <> System.pid() <> "-" <> Integer.to_string(System.system_time(:millisecond))

    hash = :crypto.hash(:sha256, material) |> binary_part(0, 2) |> Base.encode16(case: :lower)
    @name_prefix <> "-" <> hash
  end

  @doc "Returns the node name prefix used for mesh instances."
  def name_prefix, do: @name_prefix
end
