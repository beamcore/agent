defmodule Beamcore.Mesh.NodeNaming do
  @moduledoc """
  Node naming helper for the Beamcore mesh.

  The actual distributed name is set by the launcher (make chat) via
  elixir --sname. This module verifies distribution is active and
  provides helpers for name generation.
  """

  @name_prefix "beamcore"

  @doc """
  Verifies the node is distributed. Called from Application.start/2.
  Returns :ok or raises if the node is not alive (which means --sname was not passed).
  """
  def ensure_distributed! do
    if Node.alive?() do
      :ok
    else
      # Node was not started with --sname. This is not fatal for local-only use,
      # but mesh features will be unavailable.
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
