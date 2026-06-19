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
     ╔══════════════════════════════════════════╗
     ║          B E A M C O R E  ·  A G E N T   ║
     ╚══════════════════════════════════════════╝

            autonomous coding · visible workflow

    ─────────────────────────────────────────────

      quick start

        review project         generate diagram
        explain a module       make a focused change

    ─────────────────────────────────────────────

      /help  commands  @ file search  autonomous tools

      tool calls and blocked attempts appear as
      compact chat / status notices

    ─────────────────────────────────────────────

      #{total || 0} memories loaded
    """
  end

  def text(_state), do: text(%{memory_total: 0})
end
