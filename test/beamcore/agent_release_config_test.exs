defmodule Beamcore.AgentReleaseConfigTest do
  use ExUnit.Case, async: false

  test "mesh startup is controlled by application config instead of Mix at runtime" do
    previous = Application.get_env(:beamcore, :mesh_enabled)

    try do
      Application.put_env(:beamcore, :mesh_enabled, false)
      refute Beamcore.Agent.mesh_enabled?()

      Application.put_env(:beamcore, :mesh_enabled, true)
      assert Beamcore.Agent.mesh_enabled?()
    after
      restore_mesh_enabled(previous)
    end
  end

  defp restore_mesh_enabled(nil), do: Application.delete_env(:beamcore, :mesh_enabled)
  defp restore_mesh_enabled(value), do: Application.put_env(:beamcore, :mesh_enabled, value)
end
