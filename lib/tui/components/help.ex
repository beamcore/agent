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
    /timeline        Focus timeline details
    /timeline last   Open latest timeline item
    /timeline clear  Clear visible UI activity only
    /yolo            Toggle session freedom mode
    /yolo on         Bypass project policy for this session
    /yolo off        Restore project policy
    /api select      Open interactive API provider selector
    /providers       Open interactive API provider selector
    /api list        List all configured API providers
    /api use <name>  Switch active API provider
    /api add <args>  Add or update an API provider config
    /api delete <n>  Delete an API provider config
    /helper status   Show optional helper selection
    /helper models <provider>
    /helper use <provider> <model>
    /helper off      Disable helper (default)
    /login           Configure default API key
    /logout          Clear stored default login
    /quit /exit /q   Exit

    Keys
    Enter            Insert newline
    Ctrl+S           Send
    Ctrl+Enter       Send if supported by terminal
    Shift+Enter      Insert newline if supported by terminal
    Ctrl+J / Alt+Enter  Insert newline fallback
    Left/Right       Move cursor
    Up/Down          Move cursor between input lines
    /                Open command suggestions
    Up/Down          Choose command suggestion when suggestions are open
    Ctrl+P / Ctrl+N  History, or choose command suggestion
    Ctrl+O           Toggle interactive API provider selector
    Tab              Complete highlighted command suggestion
    Tab              Toggle timeline/tool details when suggestions are closed
    Timeline open: Up/Down choose item, Shift+Up/Down or PageUp/PageDown jump
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
