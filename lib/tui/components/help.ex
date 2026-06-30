defmodule Beamcore.TUI.Components.Help do
  @moduledoc """
  The global help popup, opened with `?` from any mode.

  Single source of truth for navigation and keybindings, headed by a one-line
  description of the mode the reader is currently in.
  """

  alias Beamcore.TUI.{Mode, Theme}
  alias ExRatatui.Widgets.{Block, Paragraph, Popup}

  @doc "One-line description of what a mode is for."
  @spec blurb(atom()) :: String.t()
  def blurb(:chat), do: "Talk to the agent — it reads and edits files and runs tools."

  def blurb(:dashboard),
    do: "Live token usage, providers, activity, and the BEAM mesh at a glance."

  def blurb(_coming_soon), do: "Coming soon."

  @doc "The help popup, headed by the active mode's description."
  @spec widget(atom()) :: Popup.t()
  def widget(active_id \\ Mode.default_id()) do
    %Popup{
      content: %Paragraph{text: body(active_id), style: Theme.style(:panel), wrap: true},
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

  defp body(active_id) do
    header = "Now: #{Mode.tab_title(Mode.fetch!(active_id))} — #{blurb(active_id)}"

    """
    #{header}

    Navigation
    F1 Chat          Switch to the agent chat
    F2 Dashboard     Switch to the dashboard
    F3 / F4          Coming soon
    ?                Open this help from anywhere
    Esc / q          Close this panel
    Ctrl+C           Clear the composer; when empty, press twice to pause (running) or exit (idle)

    Commands
    /clear           Clear visible chat messages
    /api list        List all configured API providers
    /api use <name>  Switch active API provider
    /api add <args>  Add or update an API provider config
    /api delete <n>  Delete an API provider config
    /env             Show redacted environment
    /theme           Switch UI themes
    /attach <name>   Attach Eeva to a project node (live runtime)
    /detach          Detach; run Eeva locally again
    /new             Start a fresh session
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
    Ctrl+P / Ctrl+N  History, or choose command suggestion
    Tab              Complete highlighted command suggestion
    Mouse wheel      Scroll the pane under the cursor
    Shift+wheel/drag Bypass capture for the terminal's native scroll/selection

    Tool output and blocked attempts appear as compact chat/status notices.
    """
    |> String.trim()
  end
end
