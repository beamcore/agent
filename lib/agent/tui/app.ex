defmodule Beamcore.Agent.TUI.App do
  @moduledoc """
  ExRatatui application loop for the primary chat UI.
  """

  alias Beamcore.Agent.TUI.{Events, Render, State}

  @max_events_per_frame 24

  def run(opts \\ []) do
    ExRatatui.run(fn terminal ->
      # Enable native terminal mouse scroll and click capture
      IO.write("\e[?1000h\e[?1002h\e[?1006h")

      try do
        terminal
        |> State.new(ExRatatui.textarea_new(), opts)
        |> State.mark_dirty()
        |> loop()
      after
        # Restore terminal mouse settings on exit
        IO.write("\e[?1000l\e[?1002l\e[?1006l")
      end
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

  defp drain_terminal_events(state, _remaining) do
    # Poll all available events in the queue, up to 500 events
    events = poll_available_events([], 500)

    # Determine if this batch of events constitutes a paste.
    # We define a paste as having more than 1 key press event in a single batch.
    key_press_count =
      Enum.count(events, fn
        %ExRatatui.Event.Key{} = event -> key_press?(event)
        _ -> false
      end)

    paste? = key_press_count > 1

    process_events(events, state, paste: paste?)
  end

  defp poll_available_events(acc, remaining) when remaining <= 0, do: Enum.reverse(acc)

  defp poll_available_events(acc, remaining) do
    case ExRatatui.poll_event(0) do
      nil ->
        Enum.reverse(acc)

      event ->
        poll_available_events([event | acc], remaining - 1)
    end
  end

  defp key_press?(%ExRatatui.Event.Key{kind: kind}), do: kind in [nil, "press", :press]
  defp key_press?(_), do: false

  defp process_events([], state, _opts), do: state

  defp process_events([event | rest], state, opts) do
    case Events.handle_event(event, state, opts) do
      {:stop, next_state} ->
        %{next_state | status: :quit}

      {:noreply, next_state} ->
        process_events(rest, State.mark_dirty(next_state), opts)
    end
  end
end
