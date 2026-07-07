defmodule Beamcore.TUI.Components.ComingSoon do
  @moduledoc """
  Body rendered for a registered-but-not-yet-built mode (F3 Research).

  Framed in the same rounded, accent-titled card as the chat so switching to a
  placeholder feels continuous rather than empty — a centered note inside the
  card reveals the mode's name.
  """

  alias Beamcore.TUI.{Glyphs, Mode, Theme}
  alias ExRatatui.Widgets.{Block, Paragraph}

  @doc "Centered placeholder body for a coming-soon mode, framed like the chat."
  @spec widget(Mode.t(), boolean()) :: Paragraph.t()
  def widget(%Mode{name: name}, unicode? \\ true) do
    %Paragraph{
      text: "\n#{name}\n\nComing soon\n\nThis surface is reserved for an upcoming milestone.",
      style: Theme.style(:muted),
      alignment: :center,
      wrap: true,
      block: %Block{
        title: "#{Glyphs.diamond(unicode?)} #{name}",
        borders: [:all],
        border_type: Glyphs.border_type(unicode?),
        border_style: Theme.style(:border),
        title_style: Theme.style(:accent),
        padding: {1, 1, 0, 0}
      }
    }
  end
end
