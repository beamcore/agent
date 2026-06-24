defmodule Beamcore.TUI.Components.System do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System.{Mesh, Stats}
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  defstruct screen_type: :system,
            configure_for: :agent,
            providers: nil,
            mesh_snapshot: nil,
            stats_snapshot: nil,
            mesh_refresh_ref: nil,
            mesh_updated_at_ms: nil

  def new(configure_for \\ :agent) do
    %__MODULE__{
      configure_for: configure_for,
      providers: Providers.new(configure_for),
      mesh_snapshot: Mesh.local_snapshot(),
      stats_snapshot: Stats.snapshot()
    }
  end

  def render_text(system, width, height \\ nil) do
    width = max(width, 1)
    accent = Theme.style(:accent)
    subtle = Theme.style(:subtle)
    flourish = String.duplicate("· ", max(div(width - 24, 2), 0))

    mesh_lines = Mesh.render(system.mesh_snapshot || Mesh.local_snapshot(), width)
    divider_w = max(76, width - 4)

    mesh_header = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ◆ Mesh Topology  ", style: accent},
          %Span{content: flourish, style: subtle}
        ]
      },
      %Line{spans: [%Span{content: ""}]}
    ]

    top = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ◆ Beamcore Agent  ", style: accent},
          %Span{content: flourish, style: subtle}
        ]
      },
      %Line{spans: [%Span{content: ""}]}
    ]

    divider = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ╰─ ", style: subtle},
          %Span{content: "Providers", style: accent},
          %Span{content: " " <> String.duplicate("─", max(divider_w - 13, 4)), style: subtle}
        ]
      },
      %Line{spans: [%Span{content: ""}]}
    ]

    bottom = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ── ", style: subtle},
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

    stats_lines = Stats.render(system.stats_snapshot || %{}, width)

    provider_reserved =
      if is_integer(height) do
        top_count = length(top) + length(stats_lines) + length(divider) + length(bottom)
        mesh_count = length(mesh_header) + length(mesh_lines)
        max(height - top_count - mesh_count, 5)
      end

    provider_items = Providers.render_items(system.providers, width, provider_reserved)

    top ++ stats_lines ++ divider ++ provider_items ++ bottom ++ mesh_header ++ mesh_lines
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

  def handle_event(event, system) do
    case Providers.handle_event(event, system.providers) do
      {:noreply, updated} -> {:noreply, %{system | providers: updated}}
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
end
