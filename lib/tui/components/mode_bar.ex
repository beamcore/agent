defmodule Beamcore.TUI.Components.ModeBar do
  @moduledoc """
  The shell's top mode bar.

  Renders every `Beamcore.TUI.Mode` as a `Tabs` widget: the active mode is
  highlighted with the `status_hot` token, live modes use `status`, and
  coming-soon placeholders are dimmed with `muted`.
  """

  alias Beamcore.TUI.{Mode, Theme}
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Tabs

  @doc "Builds the mode bar tabs with `active_id` selected."
  @spec tabs(atom()) :: Tabs.t()
  def tabs(active_id) do
    %Tabs{
      titles: Enum.map(Mode.all(), &title/1),
      selected: Mode.index(active_id),
      style: Theme.style(:status),
      highlight_style: Theme.style(:status_hot),
      divider: " "
    }
  end

  defp title(mode) do
    %Span{content: Mode.tab_title(mode), style: title_style(mode)}
  end

  defp title_style(mode) do
    if Mode.coming_soon?(mode), do: Theme.style(:muted), else: Theme.style(:status)
  end
end
