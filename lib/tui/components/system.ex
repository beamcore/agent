defmodule Beamcore.TUI.Components.System do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System.{Mesh, Stats}

  defstruct screen_type: :system,
            configure_for: :agent,
            providers: nil,
            mesh_snapshot: nil,
            stats_snapshot: nil,
            mesh_refresh_ref: nil,
            mesh_updated_at_ms: nil,
            # Snapshot of the chat's activity trace, injected by the shell at
            # render time (the trace itself lives on the chat state).
            activity: [],
            # Shared Ctrl+C arm flag, injected by the shell at render time so the
            # status bar can surface the "press again" hint (it lives on chat).
            ctrl_c_pending: false

  def new(configure_for \\ :agent) do
    %__MODULE__{
      configure_for: configure_for,
      providers: Providers.new(configure_for),
      mesh_snapshot: Mesh.local_snapshot(),
      stats_snapshot: Stats.snapshot()
    }
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
