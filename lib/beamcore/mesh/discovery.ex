defmodule Beamcore.Mesh.Discovery do
  @moduledoc """
  Automatic peer discovery for the Beamcore mesh.

  Two discovery mechanisms run in parallel:

    * **UDP broadcast** – peers on the LAN broadcast beacons on a fixed port.
    * **EPMD poll** – queries the local Erlang Port Mapper Daemon for any
      `beamcore-*` nodes registered on this machine. This covers the common
      local-development case where multiple nodes share a host and UDP
      broadcast delivery is unreliable due to port reuse.

  Zero configuration needed — just start multiple instances.
  """

  use GenServer
  require Logger

  @port 45876
  @broadcast_interval_ms 3_000
  @epmd_poll_interval_ms 4_000
  @beacon_prefix "BEAMCORE_MESH:1:"

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate EPMD poll."
  def poll_epmd, do: send(__MODULE__, :poll_epmd)

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    socket = open_udp_socket()
    schedule_broadcast()
    schedule_epmd_poll()
    {:ok, %{socket: socket, seen: %{}}}
  end

  # -- UDP broadcast --

  @impl true
  def handle_info(:broadcast, %{socket: nil} = state), do: {:noreply, state}

  def handle_info(:broadcast, %{socket: socket} = state) do
    beacon = @beacon_prefix <> Atom.to_string(Node.self())
    :gen_udp.send(socket, {255, 255, 255, 255}, @port, beacon)
    schedule_broadcast()
    {:noreply, state}
  end

  def handle_info({:udp, socket, _from_ip, _from_port, data}, %{socket: socket} = state) do
    new_state =
      case parse_beacon(data) do
        {:ok, node_name} -> handle_discovered_peer(node_name, state)
        _ -> state
      end
    {:noreply, new_state}
  end

  # -- EPMD poll --

  def handle_info(:poll_epmd, state) do
    new_state = discover_via_epmd(state)
    schedule_epmd_poll()
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal: UDP ---

  defp open_udp_socket do
    case :gen_udp.open(@port, [
      :binary,
      {:active, true},
      {:reuseaddr, true},
      {:broadcast, true},
      {:ip, {0, 0, 0, 0}}
    ]) do
      {:ok, socket} ->
        Logger.info("[Discovery] UDP listening on port " <> Integer.to_string(@port))
        socket

      {:error, :eaddrinuse} ->
        Logger.warning("[Discovery] UDP port #{@port} in use, falling back to EPMD-only discovery")
        nil

      {:error, reason} ->
        Logger.warning("[Discovery] UDP open failed: #{inspect(reason)}, falling back to EPMD-only")
        nil
    end
  end

  defp schedule_broadcast do
    Process.send_after(self(), :broadcast, @broadcast_interval_ms)
  end

  # --- Internal: EPMD ---

  defp schedule_epmd_poll do
    Process.send_after(self(), :poll_epmd, @epmd_poll_interval_ms)
  end

  defp discover_via_epmd(state) do
    prefix = Beamcore.Mesh.NodeNaming.name_prefix()

    case :erl_epmd.names() do
      {:ok, names} ->
        names
        |> Enum.map(fn {name, _port} -> to_string(name) end)
        |> Enum.filter(&String.starts_with?(&1, prefix <> "-"))
        |> Enum.map(fn name -> String.to_atom(name <> "@" <> hostname()) end)
        |> Enum.reject(&(&1 == Node.self()))
        |> Enum.reduce(state, fn peer, acc -> handle_discovered_peer(peer, acc) end)

      {:error, reason} ->
        Logger.debug("[Discovery] EPMD query failed: #{inspect(reason)}")
        state
    end
  end

  defp hostname do
    node = Atom.to_string(Node.self())
    case String.split(node, "@", parts: 2) do
      [_, host] -> host
      _ -> "localhost"
    end
  end

  # --- Internal: shared ---

  defp handle_discovered_peer(node_name, state) do
    cond do
      node_name == Node.self() ->
        state

      node_name in Node.list() ->
        %{state | seen: Map.put(state.seen, node_name, System.monotonic_time(:second))}

      true ->
        Logger.info("[Discovery] Found peer: #{node_name}")
        Node.connect(node_name)
        %{state | seen: Map.put(state.seen, node_name, System.monotonic_time(:second))}
    end
  end

  defp parse_beacon(data) do
    case data do
      "BEAMCORE_MESH:1:" <> node_str ->
        trimmed = String.trim(node_str)
        if valid_node_name?(trimmed) do
          {:ok, String.to_existing_atom(trimmed)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp valid_node_name?(name) do
    String.starts_with?(name, "beamcore-") and
      String.length(name) > 9 and
      String.match?(name, ~r/^beamcore-[a-f0-9]+$/)
  end

end
