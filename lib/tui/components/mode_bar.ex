defmodule Beamcore.TUI.Components.ModeBar do
  @moduledoc """
  The shell's top mode bar.

  Renders every `Beamcore.TUI.Mode` as a `Tabs` widget: the active mode is a
  filled chip (`chip_style/0`, accent bg), live modes use `status`, and
  coming-soon placeholders are dimmed with `muted`.
  """

  alias Beamcore.TUI.{Mode, Theme}
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Tabs

  @doc "Builds the mode bar tabs with `active_id` selected."
  @spec tabs(atom(), boolean()) :: Tabs.t()
  def tabs(active_id, unicode? \\ true) do
    %Tabs{
      titles: Enum.map(Mode.all(), &title(&1, active_id, unicode?)),
      selected: Mode.index(active_id),
      style: Theme.style(:status),
      highlight_style: Theme.chip_style(),
      divider: " "
    }
  end

  defp title(mode, active_id, unicode?) do
    %Span{
      content: Mode.tab_title(mode, mode.id == active_id, unicode?),
      style: title_style(mode)
    }
  end

  defp title_style(mode) do
    if Mode.coming_soon?(mode), do: Theme.style(:muted), else: Theme.style(:status)
  end
end
