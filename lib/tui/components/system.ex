defmodule Beamcore.TUI.Components.System do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System.{Attach, Mesh, Section, Stats}
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

  def render_text(system, width, _height \\ nil) do
    width = max(width, 1)
    accent = Theme.style(:accent)
    subtle = Theme.style(:subtle)
    flourish = String.duplicate("· ", max(div(width - 24, 2), 0))

    # ── Page header ──
    header = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ◆ Beamcore Agent  ", style: accent},
          %Span{content: flourish, style: subtle}
        ]
      },
      %Line{spans: [%Span{content: ""}]}
    ]

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
    provider_lines = Providers.render_items(system.providers)
    provider_section = Section.section("Providers", provider_lines, width)
    mesh_lines = Mesh.render(system.mesh_snapshot || Mesh.local_snapshot(), width)
    mesh_section = Section.section("Mesh", mesh_lines, width)
    attach_section = Section.section("Eeva Runtime", Attach.lines(), width, icon: "▸")

    header ++
      stats_section ++
      provider_section ++
      hints ++
      attach_section ++
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
