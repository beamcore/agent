defmodule Beamcore.TUI.Components.Help do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.{Block, Paragraph, Popup}

  def widget do
    text = """
    Commands
    /help            Show this panel
    /new             Start a fresh session
    /context         Show compact session context
    /context clear   Clear compact session context
    /policy          Show project policy summary
    /policy show     Show normalized project policy config
    /policy init     Create .beamcore/policy.json
    /policy reload   Reload project policy
    /policy deny path <pattern>
    /policy allow-write <pattern>
    /policy read-only <pattern>
    /policy tool <tool> allow|deny
    /yolo            Toggle session freedom mode
    /yolo on         Bypass project policy for this session
    /yolo off        Restore project policy
    /quit /exit /q   Exit

    Keys
    Enter            Send, or accept highlighted command suggestion
    Ctrl+S           Send
    Shift+Enter      Insert newline if supported by terminal
    Ctrl+J / Alt+Enter  Insert newline fallback
    /                Open command suggestions
    Up/Down          Choose command suggestion when suggestions are open
    Ctrl+P / Ctrl+N  History, or choose command suggestion
    Tab              Complete highlighted command suggestion
    Esc              Close suggestions, help, or details
    q                Close this panel
    Ctrl+C           Exit

    Tools, blocked attempts, validation, and image generation appear in Activity.
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
