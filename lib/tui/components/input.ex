defmodule Beamcore.TUI.Components.Input do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.{Block, Textarea}

  @hint "Ctrl+s send · @ files · / commands"
  @working [:thinking, :tool_running, :local_search, :rate_limited]
  @braille ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  @ascii ["|", "/", "-", "\\"]

  def widget(state) do
    %Textarea{
      state: state.textarea,
      style: Theme.style(:input),
      cursor_style: Theme.style(:cursor),
      placeholder: "Ask BeamCore, describe a change, or type /help",
      placeholder_style: Theme.style(:muted),
      block: %Block{
        title: title(state),
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.border(state.status),
        padding: {1, 1, 0, 0}
      }
    }
  end

  # While the agent works, the composer title becomes an animated status
  # indicator; otherwise it shows the static key hint.
  defp title(%{status: status} = state) when status in @working do
    "#{spinner(state)} #{label(status)}…"
  end

  defp title(_state), do: @hint

  defp spinner(%{spinner_step: step, unicode?: unicode?}) do
    frames = if unicode?, do: @braille, else: @ascii
    Enum.at(frames, rem(step, length(frames)))
  end

  defp label(:thinking), do: "thinking"
  defp label(:tool_running), do: "running tools"
  defp label(:local_search), do: "searching"
  defp label(:rate_limited), do: "rate limited"
end
