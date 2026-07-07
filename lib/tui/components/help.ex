defmodule Beamcore.TUI.Components.Help do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.{Block, Paragraph, Popup}

  def widget do
    text = """
    Commands
    /help            Show this panel
    /clear           Clear visible chat messages
    /api list        List all configured API providers
    /api use <name>  Switch active API provider
    /api add <args>  Add or update an API provider config
    /api delete <n>  Delete an API provider config
    /memory list     List memory counts
    /memory search   Search memory
    /memory forget   Delete memory by key
    /memory clear    Clear memory
    /env             Show redacted environment
    /theme           Switch UI themes
    /attach <name>   Attach Eeva to a project node (live runtime)
    /detach          Detach; run Eeva locally again
    /quit /exit /q   Exit

    Keys
    Enter            Insert newline
    Ctrl+S           Send
    Ctrl+A           Select all input text
    Ctrl+Enter       Send if supported by terminal
    Shift+Enter      Insert newline if supported by terminal
    Ctrl+J / Alt+Enter  Insert newline fallback
    Left/Right       Move cursor
    Up/Down          Move cursor between input lines
    PgUp/PgDn        Scroll chat history by a page
    /                Open command suggestions
    Up/Down          Choose command suggestion when suggestions are open
    Ctrl+P / Ctrl+N  History, or choose command suggestion
    Tab              Complete highlighted command suggestion
    Mouse wheel     Scroll the pane under the cursor
    Shift+wheel/drag Bypass capture for the terminal's native scroll/selection
    Esc              Close suggestions, help, or details
    q                Close this panel
    Ctrl+C           Clear the composer; when empty, press twice to pause (running) or exit (idle)

    Tool output and blocked attempts appear as compact chat/status notices.
    """

    %Popup{
      content: %Paragraph{text: String.trim(text), style: Theme.style(:panel), wrap: true},
      block: %Block{
        title: "Help",
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:border_hot),
        padding: {1, 1, 0, 0}
      },
      percent_width: 64,
      percent_height: 64
    }
  end
end
