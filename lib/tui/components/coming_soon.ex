defmodule Beamcore.TUI.Components.ComingSoon do
  @moduledoc """
  Body rendered for a registered-but-not-yet-built mode (F3/F4).

  A centered placeholder that reveals the mode's name so the shell can carry a
  new surface before its feature exists.
  """

  alias Beamcore.TUI.{Mode, Theme}
  alias ExRatatui.Widgets.Paragraph

  @doc "Centered placeholder body for a coming-soon mode."
  @spec widget(Mode.t()) :: Paragraph.t()
  def widget(%Mode{name: name}) do
    %Paragraph{
      text: "#{name}\n\nComing soon",
      style: Theme.style(:muted),
      alignment: :center,
      wrap: true
    }
  end
end
