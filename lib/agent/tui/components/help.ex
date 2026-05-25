defmodule Beamcore.Agent.TUI.Components.Help do
  @moduledoc false

  alias Beamcore.Agent.TUI.Theme
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
    /policy tool <tool> allow|confirm|deny
    /policy reload   Reload project policy
    /yolo            Enable all tools with unrestricted access
    /quit /exit /q   Exit

    Keys
    Enter            Send
    Shift+Enter      New line when supported
    Ctrl+S           Send
    Tab              Tool details
    Up/Down          Scroll chat or command menu
    Esc / q / Enter  Close this panel
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
