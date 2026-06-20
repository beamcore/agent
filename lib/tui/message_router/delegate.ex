defmodule Beamcore.TUI.MessageRouter.Delegate do
  @moduledoc false

  alias Beamcore.TUI.{Events, MessageRouter}

  def call(event, state, screen) do
    screen_state = MessageRouter.screen_state(state, screen)

    case Events.handle_event(event, screen_state) do
      {:stop, new_screen_state} ->
        {:stop, MessageRouter.put_screen_state(state, screen, new_screen_state)}

      {:noreply, new_screen_state} ->
        new_state = MessageRouter.put_screen_state(state, screen, new_screen_state)

        if Map.get(new_screen_state, :status) == :quit,
          do: {:stop, new_state},
          else: {:noreply, new_state}
    end
  end
end
