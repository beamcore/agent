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
            # render time (the trace itself lives on the chat state) and kept in
            # sync on the dashboard tick so key handling can clamp the scroll.
            activity: [],
            # Which panel has keyboard focus: :providers (default) or :activity.
            # Tab cycles it; the focused panel's border is highlighted.
            active_panel: :providers,
            # Top line offset for the Activity log when it is focused.
            activity_offset: 0,
            # Shared Ctrl+C arm flag, injected by the shell at render time so the
            # status bar can surface the "press again" hint (it lives on chat).
            ctrl_c_pending: false,
            # Terminal unicode capability, injected by the shell at render time
            # (it lives on the chat state) so the panels pick ASCII fallbacks on
            # terminals that cannot render the framing glyphs.
            unicode?: true

  @activity_page 5

  def new(configure_for \\ :agent) do
    %__MODULE__{
      configure_for: configure_for,
      providers: Providers.new(configure_for),
      mesh_snapshot: Mesh.local_snapshot(),
      stats_snapshot: Stats.snapshot()
    }
  end

  def mark_dirty(system), do: system

  # While the add-provider form is open it owns every key (Tab moves between
  # fields), so panel cycling is suspended until the form is dismissed.
  def handle_event(%ExRatatui.Event.Key{} = event, %{providers: %{adding?: true}} = system) do
    delegate_providers(event, system)
  end

  def handle_event(%ExRatatui.Event.Key{code: code}, system) when code in ["tab", "back_tab"] do
    {:noreply, toggle_panel(system)}
  end

  # When Activity is focused it consumes the scroll keys; other keys are inert
  # (providers actions like add/delete only fire while Providers is focused).
  def handle_event(%ExRatatui.Event.Key{code: code}, %{active_panel: :activity} = system) do
    case activity_scroll(code) do
      nil -> {:noreply, system}
      move -> {:noreply, scroll_activity(system, move)}
    end
  end

  def handle_event(event, system), do: delegate_providers(event, system)

  @doc "Clamps the Activity scroll offset to the current trace length."
  def clamp_activity_offset(%__MODULE__{} = system) do
    max_offset = max(length(system.activity) - 1, 0)
    %{system | activity_offset: system.activity_offset |> max(0) |> min(max_offset)}
  end

  defp delegate_providers(event, system) do
    case Providers.handle_event(event, system.providers) do
      {:noreply, updated} -> {:noreply, %{system | providers: updated}}
    end
  end

  defp toggle_panel(%{active_panel: :providers} = system), do: %{system | active_panel: :activity}
  defp toggle_panel(system), do: %{system | active_panel: :providers}

  defp activity_scroll("up"), do: -1
  defp activity_scroll("down"), do: 1
  defp activity_scroll(code) when code in ["page_up", "pageup", "pgup"], do: -@activity_page
  defp activity_scroll(code) when code in ["page_down", "pagedown", "pgdown"], do: @activity_page
  defp activity_scroll("home"), do: :home
  defp activity_scroll("end"), do: :end
  defp activity_scroll(_code), do: nil

  defp scroll_activity(system, :home), do: %{system | activity_offset: 0}

  defp scroll_activity(system, :end),
    do: %{system | activity_offset: max(length(system.activity) - 1, 0)}

  defp scroll_activity(system, delta) when is_integer(delta) do
    max_offset = max(length(system.activity) - 1, 0)
    %{system | activity_offset: (system.activity_offset + delta) |> max(0) |> min(max_offset)}
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
