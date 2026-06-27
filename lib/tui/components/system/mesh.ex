defmodule Beamcore.TUI.Components.System.Mesh do
  @moduledoc "Real-time mesh topology visualization for the F3 screen."

  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}

  @rpc_timeout_ms 100

  # ── Public API ──

  def render(snapshot, width) do
    build_lines(snapshot, width)
  end

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

  # ── Line Building ──
  # Returns content-only lines (no section header — Section handles that).

  defp build_lines(snapshot, _width) do
    accent = Theme.style(:accent)
    subtle = Theme.style(:subtle)
    muted = Theme.style(:muted)
    done = Theme.style(:done)
    base = Theme.style(:base)

    # Self node + peers
    self_lines = node_row(snapshot.self_info, accent, done, base, subtle, muted, true)

    peer_lines =
      if snapshot.peers == [] do
        [
          %Line{
            spans: [
              %Span{content: "  no peers connected", style: muted}
            ]
          }
        ]
      else
        Enum.flat_map(snapshot.peers, fn info ->
          node_row(info, accent, done, base, subtle, muted, false)
        end)
      end

    # Summary line
    peer_count = length(snapshot.peers)
    epmd_count = map_size(snapshot.epmd_names)
    mem_mb = Float.round(snapshot.total_memory / 1_048_576, 1)

    summary = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: "  peers ", style: muted},
          %Span{content: "#{peer_count}", style: accent},
          %Span{content: "  ·  epmd ", style: muted},
          %Span{content: "#{epmd_count}", style: accent},
          %Span{content: "  ·  total memory ", style: muted},
          %Span{content: "#{mem_mb} MB", style: accent},
          %Span{content: "  ·  total procs ", style: muted},
          %Span{content: "#{snapshot.total_processes}", style: accent}
        ]
      }
    ]

    self_lines ++ peer_lines ++ summary
  end

  defp node_row(info, accent, done, base, subtle, muted, is_self?) do
    dot = if is_self?, do: "●", else: "○"
    dot_style = if is_self?, do: done, else: accent
    label = if is_self?, do: "self", else: "peer"

    mem_mb = Float.round(info.memory / 1_048_576, 1)
    uptime = format_uptime(info.uptime_ms)
    latency = if info.latency_us > 0, do: "#{Float.round(info.latency_us / 1000, 1)}ms", else: nil
    lat_style = if info.latency_us > 5000, do: Theme.style(:error), else: done

    latency_span =
      if latency do
        [%Span{content: "  ·  latency ", style: muted}, %Span{content: latency, style: lat_style}]
      else
        []
      end

    [
      %Line{
        spans:
          [
            %Span{content: "  ", style: base},
            %Span{content: "#{dot} ", style: dot_style},
            %Span{content: "#{info.short_name}", style: accent},
            %Span{content: "@#{info.host}", style: muted},
            %Span{content: "  [#{label}]", style: dot_style},
            %Span{content: "  ·  ", style: subtle},
            %Span{content: "#{mem_mb} MB", style: base},
            %Span{content: "  ·  procs ", style: muted},
            %Span{content: "#{info.process_count}", style: base},
            %Span{content: "  ·  sched ", style: muted},
            %Span{content: "#{info.schedulers}", style: base},
            %Span{content: "  ·  up ", style: muted},
            %Span{content: uptime, style: base}
          ] ++ latency_span
      }
    ]
  end

  defp format_uptime(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_uptime(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  defp format_uptime(ms) when ms < 3_600_000,
    do: "#{div(ms, 60_000)}m #{rem(div(ms, 1_000), 60)}s"

  defp format_uptime(ms) do
    h = div(ms, 3_600_000)
    m = rem(div(ms, 60_000), 60)
    "#{h}h #{m}m"
  end
end
