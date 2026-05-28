defmodule Beamcore.TUI.Components.EmptyState do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.Paragraph

  def widget(text) when is_binary(text) do
    %Paragraph{
      text: String.trim(text),
      style: Theme.style(:system),
      alignment: :center,
      wrap: false
    }
  end

  def text(%{memory_total: total}) do
    """
    BEAMCORE.AGENT
    Fast, visible coding workflow for this workspace

    Quick starts
      Review project        Generate diagram
      Explain a module      Make a focused change

    /help commands    Tab activity details    autonomous tools
    Tool calls, plans, and policy blocks appear in Activity.

    Available #{total || 0} memories
    """
  end

  def text(_state), do: text(%{memory_total: 0})
end
