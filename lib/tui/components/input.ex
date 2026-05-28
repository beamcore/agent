defmodule Beamcore.TUI.Components.Input do
  @moduledoc false

  alias Beamcore.TUI.{State, Theme}
  alias ExRatatui.Widgets.{Block, Textarea}

  def widget(state) do
    pending? = State.pending_action(state.session) != nil

    title =
      if pending? do
        "Pending action · /cancel clears · Ctrl+S send · / commands"
      else
        "Enter send · Ctrl+S send · Tab complete · Up/Down choose · Esc close · / commands"
      end

    %Textarea{
      state: state.textarea,
      style: Theme.style(:input),
      cursor_style: Theme.style(:cursor),
      placeholder: "Ask BeamCore, describe a change, or type /help",
      placeholder_style: Theme.style(:muted),
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.border(state.status),
        padding: {1, 1, 0, 0}
      }
    }
  end
end
