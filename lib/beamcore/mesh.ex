defmodule Beamcore.Mesh do
  @moduledoc """
  Automatic peer discovery and connection for multi-node Beamcore clusters.

  Each make-chat instance becomes a distributed Erlang node.
  On startup the Mesh GenServer connects to peers listed in
  BEAMCORE_PEERS env var and monitors nodeup/nodedown events.

  ## Environment Variables

    * BEAMCORE_PEERS - comma-separated node names to connect to
    * BEAMCORE_NODE_NAME - override the auto-generated node name
  """

  use GenServer
  require Logger

  @retry_interval_ms 5_000
  @max_retries 12

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns connected peer nodes (excluding self)."
  def peers, do: Node.list()

  @doc "Returns cluster info: self + connected peers."
  def cluster_info do
    %{
      node: Node.self(),
      alive?: Node.alive?(),
      peers: Node.list(),
      peer_count: length(Node.list())
    }
  end

  @doc "Attempt to connect to a specific node."
  def connect(node) when is_atom(node), do: GenServer.cast(__MODULE__, {:connect, node})
  def connect(node) when is_binary(node), do: node |> String.to_atom() |> connect()

  @doc "Refresh peer list from environment."
  def refresh_peers, do: GenServer.cast(__MODULE__, :refresh_peers)

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true)
    send(self(), :connect_initial_peers)
    {:ok, %{known_peers: MapSet.new(), connect_failures: %{}}}
  end

  @impl true
  def handle_info(:connect_initial_peers, state) do
    peers = env_peers()
    new_known = MapSet.union(state.known_peers, MapSet.new(peers))
    Enum.each(peers, &attempt_connect/1)
    {:noreply, %{state | known_peers: new_known}}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.info("[Mesh] Node connected: " <> inspect(node))
    {:noreply, %{state | connect_failures: Map.delete(state.connect_failures, node)}}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.info("[Mesh] Node disconnected: " <> inspect(node))

    if MapSet.member?(state.known_peers, node) do
      Process.send_after(self(), {:retry_connect, node}, @retry_interval_ms)
    end

    {:noreply, state}
  end

  def handle_info({:retry_connect, node}, state) do
    if node not in Node.list() do
      case attempt_connect(node) do
        :ok ->
          Logger.info("[Mesh] Reconnected to " <> inspect(node))
          {:noreply, %{state | connect_failures: Map.delete(state.connect_failures, node)}}

        _ ->
          count = Map.get(state.connect_failures, node, 0) + 1

          if count < @max_retries do
            delay = min(@retry_interval_ms * Integer.pow(2, min(count, 4)), 60_000)
            Process.send_after(self(), {:retry_connect, node}, delay)
            {:noreply, %{state | connect_failures: Map.put(state.connect_failures, node, count)}}
          else
            Logger.warning(
              "[Mesh] Giving up on " <>
                inspect(node) <> " after " <> Integer.to_string(count) <> " attempts"
            )

            {:noreply, %{state | connect_failures: Map.put(state.connect_failures, node, count)}}
          end
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:connect, node}, state) do
    attempt_connect(node)
    {:noreply, %{state | known_peers: MapSet.put(state.known_peers, node)}}
  end

  def handle_cast(:refresh_peers, state) do
    peers = env_peers()
    new_known = MapSet.union(state.known_peers, MapSet.new(peers))
    Enum.each(peers, fn peer -> if peer not in Node.list(), do: attempt_connect(peer) end)
    {:noreply, %{state | known_peers: new_known}}
  end

  # --- Internal ---

  defp attempt_connect(node) when is_atom(node) do
    case Node.connect(node) do
      true -> :ok
      false -> :error
      :ignored -> :ignored
    end
  end

  defp env_peers do
    case System.get_env("BEAMCORE_PEERS") do
      nil ->
        []

      "" ->
        []

      peers_str ->
        peers_str
        |> String.split(",", trim: true)
        |> Enum.map(fn s -> s |> String.trim() |> String.to_atom() end)
        |> Enum.reject(&(&1 == Node.self()))
    end
  end
end
