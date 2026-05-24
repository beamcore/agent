defmodule Beamcore.Agent.TUI.App do
  @moduledoc """
  ExRatatui application loop for the primary chat UI.
  """

  alias Beamcore.Agent.TUI.{Events, Render, State}

  @max_events_per_frame 24

  def run(opts \\ []) do
    ExRatatui.run(fn terminal ->
      terminal
      |> State.new(ExRatatui.textarea_new(), opts)
      |> State.mark_dirty()
      |> loop()
    end)
  end

  defp loop(%{status: :quit}), do: :ok

  defp loop(state) do
    state
    |> maybe_tick()
    |> maybe_draw()
    |> wait_and_dispatch()
  end

  defp wait_and_dispatch(state) do
    receive do
      {:runtime_event, event} ->
        event
        |> Events.handle_runtime_event(state)
        |> State.mark_dirty()
        |> loop()

      {:agent_done, _pid, session} ->
        state
        |> Events.finish_worker(session)
        |> State.mark_dirty()
        |> loop()
    after
      State.poll_timeout_ms(state, System.monotonic_time(:millisecond)) ->
        state
        |> drain_terminal_events(@max_events_per_frame)
        |> loop()
    end
  end

  defp maybe_draw(%{render_dirty?: true} = state) do
    ExRatatui.draw(state.terminal, Render.render(state))
    State.clear_dirty(state)
  end

  defp maybe_draw(state), do: state

  defp maybe_tick(state) do
    now = System.monotonic_time(:millisecond)

    if State.animation_due?(state, now) do
      state
      |> State.tick(now)
      |> State.mark_dirty()
    else
      state
    end
  end

  defp drain_terminal_events(state, remaining) when remaining <= 0, do: state

  defp drain_terminal_events(state, remaining) do
    case ExRatatui.poll_event(0) do
      nil ->
        state

      event ->
        case Events.handle_event(event, state) do
          {:stop, next_state} ->
            %{next_state | status: :quit}

          {:noreply, next_state} ->
            next_state
            |> State.mark_dirty()
            |> drain_terminal_events(remaining - 1)
        end
    end
  end
end
