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
    /policy deny path <pattern>
    /policy tool <tool> allow|deny
    /policy reload   Reload project policy
    /yolo            Toggle session freedom mode
    /yolo on         Bypass project policy for this session
    /yolo off        Restore project policy
    /quit /exit /q   Exit

    Keys
    Enter            New line
    Ctrl+Enter /     Send
    Ctrl+S           Send
    Ctrl+P / Ctrl+N  History / scroll command menu
    Tab              Tool details
    Up/Down          Move cursor in textarea
    Esc / q          Close this panel
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
