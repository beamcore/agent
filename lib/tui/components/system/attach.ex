defmodule Beamcore.TUI.Components.System.Attach do
  @moduledoc "Eeva runtime attach status for the F3 system screen."

  alias Beamcore.Remote.Session
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}

  @spec lines() :: [Line.t()]
  def lines do
    [
      %Line{spans: status_spans(Session.target())}
    ]
  end

  defp status_spans(:local) do
    [
      %Span{content: "  Eeva runtime  ", style: Theme.style(:muted)},
      %Span{content: "local", style: Theme.style(:base)},
      %Span{content: " (this node)", style: Theme.style(:muted)}
    ]
  end

  defp status_spans({:attached, node}) do
    [
      %Span{content: "  Eeva runtime  ", style: Theme.style(:muted)},
      %Span{content: "attached ▸ ", style: Theme.style(:done)},
      %Span{content: Atom.to_string(node), style: Theme.style(:accent)}
    ]
  end
end
