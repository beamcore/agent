defmodule Beamcore.TUI.Components.System.Mesh do
  @moduledoc "Real-time mesh topology visualization for the F3 screen."

  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.Canvas
  alias ExRatatui.Widgets.Canvas.{Circle, Label, Line, Points}

  @rpc_timeout_ms 100
  @peer_radius 0.7

  # ── Public API ──

  @doc "The cluster topology as a native braille `Canvas` node-graph."
  def canvas(snapshot) do
    peers = position_peers(snapshot.peers)

    links =
      Enum.map(peers, fn {_info, x, y} ->
        %Line{x1: 0.0, y1: 0.0, x2: x, y2: y, color: color(:subtle)}
      end)

    peer_shapes =
      Enum.flat_map(peers, fn {info, x, y} ->
        [
          %Points{coords: [{x, y}], color: color(:done)},
          %Label{x: x, y: y, text: info.short_name, color: color(:muted)}
        ]
      end)

    self_shapes = [
      %Circle{x: 0.0, y: 0.0, radius: 0.12, color: color(:accent)},
      %Label{x: 0.0, y: -0.32, text: snapshot.self_info.short_name, color: color(:accent)}
    ]

    %Canvas{
      x_bounds: {-1.2, 1.2},
      y_bounds: {-1.2, 1.2},
      marker: :braille,
      shapes: links ++ peer_shapes ++ self_shapes
    }
  end

  @doc "A one-line cluster summary for the panel caption."
  def summary(snapshot) do
    mem_mb = Float.round(snapshot.total_memory / 1_048_576, 1)

    "peers #{length(snapshot.peers)} · epmd #{map_size(snapshot.epmd_names)} · " <>
      "#{mem_mb} MB · procs #{snapshot.total_processes}"
  end

  defp position_peers(peers) do
    peers
    |> Enum.with_index()
    |> Enum.map(fn {info, i} ->
      angle = 2 * :math.pi() * i / length(peers)
      {info, @peer_radius * :math.cos(angle), @peer_radius * :math.sin(angle)}
    end)
  end

  defp color(role), do: Theme.style(role).fg || :white

  def local_snapshot do
    self_node = Node.self()
    self_info = node_info(self_node, true)

    %{
      self_node: self_node,
      peers: [],
      total_nodes: 1,
      epmd_names: %{},
      self_info: self_info,
      total_memory: self_info.memory,
      total_processes: self_info.process_count
    }
  end

  def collect_snapshot do
    self_node = Node.self()
    peers = Node.list()

    epmd_names =
      case :erl_epmd.names() do
        {:ok, names} -> Map.new(names)
        _ -> %{}
      end

    self_info = node_info(self_node, true)
    peer_infos = Enum.map(peers, fn n -> node_info(n, false) end)

    total_mem = self_info.memory + Enum.sum(Enum.map(peer_infos, & &1.memory))
    total_procs = self_info.process_count + Enum.sum(Enum.map(peer_infos, & &1.process_count))

    %{
      self_node: self_node,
      peers: peer_infos,
      total_nodes: 1 + length(peers),
      epmd_names: epmd_names,
      self_info: self_info,
      total_memory: total_mem,
      total_processes: total_procs
    }
  end

  # ── Node Info Collection ──

  defp node_info(node, is_self) do
    name_str = Atom.to_string(node)
    [short_name, host] = String.split(name_str, "@", parts: 2)

    {memory, process_count, schedulers, uptime_ms} =
      if is_self do
        {_, up} = :erlang.statistics(:wall_clock)

        {:erlang.memory(:total), :erlang.system_info(:process_count),
         :erlang.system_info(:schedulers_online), up}
      else
        mem = safe_rpc(node, :erlang, :memory, [:total], 0)
        procs = safe_rpc(node, :erlang, :system_info, [:process_count], 0)
        scheds = safe_rpc(node, :erlang, :system_info, [:schedulers_online], 0)

        up =
          case :rpc.call(node, :erlang, :statistics, [:wall_clock], @rpc_timeout_ms) do
            {_, ms} -> ms
            _ -> 0
          end

        {mem, procs, scheds, up}
      end

    latency = if is_self, do: 0, else: measure_latency(node)

    %{
      node: node,
      short_name: short_name,
      host: host,
      is_self: is_self,
      memory: memory,
      process_count: process_count,
      schedulers: schedulers,
      uptime_ms: uptime_ms,
      latency_us: latency
    }
  end

  defp safe_rpc(node, mod, fun, args, default) do
    case :rpc.call(node, mod, fun, args, @rpc_timeout_ms) do
      {:badrpc, _} -> default
      val -> val
    end
  end

  defp measure_latency(node) do
    t0 = System.monotonic_time(:microsecond)
    :rpc.call(node, :erlang, :node, [], @rpc_timeout_ms)
    t1 = System.monotonic_time(:microsecond)
    t1 - t0
  end
end
