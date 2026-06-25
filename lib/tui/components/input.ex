defmodule Beamcore.TUI.Components.Input do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.{Block, Textarea}

  def widget(state) do
    title = "Ctrl+s send · @ files · / commands"

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
