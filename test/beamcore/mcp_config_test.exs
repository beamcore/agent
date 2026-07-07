defmodule Beamcore.MCP.ConfigTest do
  use ExUnit.Case, async: false

  alias Beamcore.MCP.Config

  setup do
    previous_enabled = Application.get_env(:beamcore, :mcp_enabled)
    previous_config_enabled = Beamcore.Config.get(:mcp_enabled)
    previous_servers = Beamcore.Config.get(:mcp_servers)

    Application.put_env(:beamcore, :mcp_enabled, false)
    Beamcore.Config.delete(:mcp_enabled)
    Beamcore.Config.delete(:mcp_servers)

    on_exit(fn ->
      restore_app_env(previous_enabled)
      restore_config(:mcp_enabled, previous_config_enabled)
      restore_config(:mcp_servers, previous_servers)
    end)

    :ok
  end

  test "MCP is disabled by default through runtime config" do
    refute Config.enabled?()

    snapshot = Config.snapshot()
    refute snapshot.enabled?
    assert snapshot.server_count == 0
    assert snapshot.servers == []
  end

  test "MCP enabled flag is runtime configurable" do
    assert :ok = Config.set_enabled(true)
    assert Config.enabled?()

    assert :ok = Config.set_enabled(false)
    refute Config.enabled?()
  end

  test "MCP server config is normalized without starting external processes" do
    assert :ok =
             Config.put_servers([
               %{name: " fs ", transport: "stdio", command: " npx ", args: ["server"]},
               %{name: "", command: "ignored", args: []},
               %{name: "bad-args", command: "cmd", args: [:not_binary]}
             ])

    assert Config.servers() == [
             %{
               "name" => "fs",
               "transport" => "stdio",
               "command" => "npx",
               "args" => ["server"]
             }
           ]
  end

  defp restore_app_env(nil), do: Application.delete_env(:beamcore, :mcp_enabled)
  defp restore_app_env(value), do: Application.put_env(:beamcore, :mcp_enabled, value)

  defp restore_config(key, nil), do: Beamcore.Config.delete(key)
  defp restore_config(key, value), do: Beamcore.Config.put(key, value)
end
