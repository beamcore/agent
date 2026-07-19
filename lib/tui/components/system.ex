defmodule Beamcore.TUI.Components.System do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System.{Attach, EevaLimits, MCP, Mesh, Section, Stats}
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  defstruct screen_type: :system,
            configure_for: :agent,
            providers: nil,
            mesh_snapshot: nil,
            mcp_snapshot: nil,
            stats_snapshot: nil,
            mesh_refresh_ref: nil,
            mesh_updated_at_ms: nil,
            scroll_offset: 0,
            viewport_height: 24

  def new(configure_for \\ :agent) do
    %__MODULE__{
      configure_for: configure_for,
      providers: Providers.new(configure_for),
      mesh_snapshot: Mesh.local_snapshot(),
      mcp_snapshot: MCP.snapshot(),
      stats_snapshot: Stats.snapshot()
    }
  end

  def render_text(system, width, height_arg \\ nil) do
    width = max(width, 1)
    height = visible_height(system, height_arg)
    lines = system |> content_lines(width) |> fit_lines(width)
    offset = effective_scroll_offset(system, lines, height)

    Enum.slice(lines, offset, height)
  end

  defp content_lines(system, width) do
    header = grid_header(width)
    accent = Theme.style(:accent)
    subtle = Theme.style(:subtle)

    # ── Keyboard hints ──
    hints = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: "  ── ", style: subtle},
          %Span{content: "enter", style: accent},
          %Span{content: " activate  ", style: Theme.style(:muted)},
          %Span{content: "a", style: accent},
          %Span{content: " add  ", style: Theme.style(:muted)},
          %Span{content: "d", style: accent},
          %Span{content: " delete  ", style: Theme.style(:muted)},
          %Span{content: "F1", style: accent},
          %Span{content: " back", style: Theme.style(:muted)}
        ]
      }
    ]

    # ── Build each section ──
    stats_section = Stats.render(system.stats_snapshot || %{}, width)
    provider_lines = Providers.render_items(system.providers, nil, width)
    provider_section = Section.section("Providers", provider_lines, width)
    mcp_section = Section.section("MCP", MCP.lines(system.mcp_snapshot || MCP.snapshot()), width)
    mesh_lines = Mesh.render(system.mesh_snapshot || Mesh.local_snapshot(), width)
    mesh_section = Section.section("Mesh", mesh_lines, width)
    attach_section = Section.section("Eeva Runtime", Attach.lines(), width, icon: "▸")
    limits_section = Section.section("Eeva Limits", EevaLimits.lines(), width, icon: "◦")

    header ++
      stats_section ++
      provider_section ++
      mcp_section ++
      hints ++
      attach_section ++
      limits_section ++
      mesh_section
  end

  def widget(system, area) do
    lines = render_text(system, area.width - 4)
    height = max(length(lines), 1)

    [
      {%Paragraph{text: lines, wrap: false}, height},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:base)}, 1}
    ]
  end

  def mark_dirty(system), do: system

  def set_viewport_height(system, height) do
    %{system | viewport_height: max(height, 1)}
  end

  def handle_event(event, %{providers: %{adding?: true}} = system) do
    {:noreply, updated} = Providers.handle_event(event, system.providers)
    {:noreply, put_providers(system, updated)}
  end

  def handle_event(event, system) do
    case event do
      %ExRatatui.Event.Key{code: "up"} ->
        handle_vertical_arrow(event, system, -1)

      %ExRatatui.Event.Key{code: "down"} ->
        handle_vertical_arrow(event, system, 1)

      %ExRatatui.Event.Key{code: "m"} ->
        {:noreply, %{system | mcp_snapshot: MCP.toggle(system.mcp_snapshot || MCP.snapshot())}}

      %ExRatatui.Event.Key{code: code} when code in ["page_up", "pageup", "pgup"] ->
        {:noreply, scroll_page(system, -page_size(system))}

      %ExRatatui.Event.Key{code: code} when code in ["page_down", "pagedown", "pgdown"] ->
        {:noreply, scroll_page(system, page_size(system))}

      %ExRatatui.Event.Key{code: "home"} ->
        {:noreply, %{system | scroll_offset: 0}}

      %ExRatatui.Event.Key{code: "end"} ->
        {:noreply, %{system | scroll_offset: max_scroll_offset(system)}}

      _ ->
        case Providers.handle_event(event, system.providers) do
          {:noreply, updated} -> {:noreply, put_providers(system, updated)}
        end
    end
  end

  def maybe_refresh_mesh(%{mesh_refresh_ref: ref} = system) when is_reference(ref), do: system

  def maybe_refresh_mesh(system) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.start(fn ->
        snapshot =
          try do
            {Mesh.collect_snapshot(), Stats.snapshot()}
          rescue
            error ->
              Beamcore.AppLog.exception(:error, error, __STACKTRACE__,
                boundary: :tui_mesh_refresh
              )

              {Mesh.local_snapshot(), %{}}
          catch
            kind, reason ->
              Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :tui_mesh_refresh)
              {Mesh.local_snapshot(), %{}}
          end

        send(parent, {:system_mesh_snapshot, ref, snapshot})
      end)

    %{system | mesh_refresh_ref: ref}
  rescue
    error ->
      Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :tui_mesh_refresh_start)
      system
  catch
    kind, reason ->
      Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :tui_mesh_refresh_start)
      system
  end

  def finish_mesh_refresh(%{mesh_refresh_ref: ref} = system, ref, snapshot)
      when is_map(snapshot) do
    %{
      system
      | mesh_snapshot: snapshot,
        mesh_refresh_ref: nil,
        mesh_updated_at_ms: System.monotonic_time(:millisecond)
    }
  end

  def finish_mesh_refresh(%{mesh_refresh_ref: ref} = system, ref, {mesh_snapshot, stats_snapshot})
      when is_map(mesh_snapshot) and is_map(stats_snapshot) do
    %{
      system
      | mesh_snapshot: mesh_snapshot,
        stats_snapshot: stats_snapshot,
        mesh_refresh_ref: nil,
        mesh_updated_at_ms: System.monotonic_time(:millisecond)
    }
  end

  def finish_mesh_refresh(system, _ref, _snapshot), do: system

  def finish_provider_save(system, ref, result) do
    %{system | providers: Providers.finish_save(system.providers, ref, result)}
  end

  def finish_provider_action(system, ref, action, result) do
    %{system | providers: Providers.finish_action(system.providers, ref, action, result)}
  end

  defp grid_header(width) do
    accent = Theme.style(:accent)
    subtle = Theme.style(:subtle)
    muted = Theme.style(:muted)
    rail = neon_rail(width)
    title = fit_text("  BEAMCORE CONTROL GRID", width)
    telemetry = fit_text("  F3 // providers // mcp // runtime // mesh", width)

    [
      %Line{spans: [%Span{content: ""}]},
      %Line{spans: [%Span{content: rail, style: subtle}]},
      %Line{
        spans: [
          %Span{content: title, style: accent},
          %Span{content: right_fill(title, width), style: subtle}
        ]
      },
      %Line{
        spans: [
          %Span{content: telemetry, style: muted},
          %Span{content: right_fill(telemetry, width), style: subtle}
        ]
      },
      %Line{spans: [%Span{content: rail, style: subtle}]},
      %Line{spans: [%Span{content: ""}]}
    ]
  end

  defp neon_rail(width) do
    cond do
      width <= 0 -> ""
      width == 1 -> "╺"
      true -> "╺" <> String.duplicate("━", max(width - 2, 0)) <> "╸"
    end
  end

  defp fit_text(text, width) do
    if String.length(text) <= width do
      text
    else
      String.slice(text, 0, max(width - 1, 0))
    end
  end

  defp right_fill(text, width) do
    fill = max(width - String.length(text), 0)
    if fill == 0, do: "", else: String.duplicate("·", fill)
  end

  defp fit_lines(lines, width), do: Enum.map(lines, &fit_line(&1, width))

  defp fit_line(%Line{spans: spans} = line, width) do
    %{line | spans: take_spans(spans, width, [])}
  end

  defp take_spans(_spans, remaining, acc) when remaining <= 0, do: Enum.reverse(acc)
  defp take_spans([], _remaining, acc), do: Enum.reverse(acc)

  defp take_spans([span | rest], remaining, acc) do
    content = span.content || ""
    len = String.length(content)

    cond do
      len <= remaining ->
        take_spans(rest, remaining - len, [span | acc])

      remaining == 0 ->
        Enum.reverse(acc)

      true ->
        Enum.reverse([%{span | content: String.slice(content, 0, remaining)} | acc])
    end
  end

  defp visible_height(system, nil), do: system.viewport_height || 24
  defp visible_height(_system, height) when is_integer(height), do: max(height, 1)
  defp visible_height(system, _height), do: system.viewport_height || 24

  defp effective_scroll_offset(system, lines, height) do
    offset =
      cond do
        system.scroll_offset > 0 ->
          system.scroll_offset

        provider_form_open?(system) ->
          provider_section_offset(lines) + provider_form_offset(system)

        true ->
          0
      end

    clamp_scroll_offset(offset, height, lines)
  end

  defp provider_form_open?(%{providers: %{adding?: true}}), do: true
  defp provider_form_open?(_system), do: false

  defp provider_form_offset(%{providers: %{form: %{scroll_offset: offset}}})
       when is_integer(offset),
       do: offset

  defp provider_form_offset(_system), do: 0

  defp provider_section_offset(lines) do
    Enum.find_index(lines, &line_contains?(&1, "Providers")) || 0
  end

  defp line_contains?(%Line{spans: spans}, text) do
    Enum.any?(spans, fn span -> String.contains?(span.content || "", text) end)
  end

  defp page_size(system), do: max((system.viewport_height || 24) - 2, 1)

  defp handle_vertical_arrow(event, system, amount) do
    {:noreply, updated_providers} = Providers.handle_event(event, system.providers)

    if updated_providers == system.providers do
      {:noreply, scroll_page(system, amount)}
    else
      {:noreply, put_providers(system, updated_providers)}
    end
  end

  defp put_providers(system, providers) do
    if provider_form_open?(%{system | providers: providers}) do
      %{system | providers: providers, scroll_offset: 0}
    else
      %{system | providers: providers}
    end
  end

  defp scroll_page(system, amount) do
    max_offset = max_scroll_offset(system)
    offset = system.scroll_offset + amount
    %{system | scroll_offset: offset |> max(0) |> min(max_offset)}
  end

  defp max_scroll_offset(system) do
    width = 100
    height = system.viewport_height || 24
    max(length(content_lines(system, width)) - height, 0)
  end

  defp clamp_scroll_offset(offset, height, lines) do
    max_offset = max(length(lines) - height, 0)
    offset |> max(0) |> min(max_offset)
  end
end
