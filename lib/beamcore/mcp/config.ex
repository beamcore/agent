defmodule Beamcore.MCP.Config do
  @moduledoc """
  Runtime-safe MCP configuration facade.

  This module only owns local configuration state. It deliberately does not
  start external MCP servers; process lifecycle belongs to the future MCP
  runtime layer.
  """

  @enabled_key :mcp_enabled
  @servers_key :mcp_servers

  def snapshot do
    servers = servers()

    %{
      enabled?: enabled?(),
      server_count: length(servers),
      servers: servers
    }
  end

  def enabled? do
    case Beamcore.Config.get(@enabled_key) do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:beamcore, @enabled_key, false)
    end
  rescue
    _ -> Application.get_env(:beamcore, @enabled_key, false)
  catch
    _, _ -> Application.get_env(:beamcore, @enabled_key, false)
  end

  def set_enabled(enabled?) when is_boolean(enabled?) do
    Application.put_env(:beamcore, @enabled_key, enabled?)
    Beamcore.Config.put(@enabled_key, Atom.to_string(enabled?))
  end

  def toggle_enabled do
    set_enabled(not enabled?())
  end

  def servers do
    case Beamcore.Config.get(@servers_key) do
      json when is_binary(json) ->
        decode_servers(json)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def put_servers(servers) when is_list(servers) do
    servers
    |> Enum.map(&normalize_server/1)
    |> Enum.reject(&is_nil/1)
    |> Jason.encode!()
    |> then(&Beamcore.Config.put(@servers_key, &1))
  end

  defp decode_servers(json) do
    case Jason.decode(json) do
      {:ok, servers} when is_list(servers) ->
        servers
        |> Enum.map(&normalize_server/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp normalize_server(%{} = server) do
    name = map_value(server, "name")
    command = map_value(server, "command")
    args = map_value(server, "args") || []

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        nil

      not is_binary(command) or String.trim(command) == "" ->
        nil

      not is_list(args) ->
        nil

      not Enum.all?(args, &is_binary/1) ->
        nil

      true ->
        %{
          "name" => String.trim(name),
          "transport" => map_value(server, "transport") || "stdio",
          "command" => String.trim(command),
          "args" => args
        }
    end
  end

  defp normalize_server(_server), do: nil

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
