defmodule Beamcore.TUI.Components.System.MCP do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}

  def snapshot, do: Beamcore.MCP.Config.snapshot()

  def toggle(snapshot) when is_map(snapshot) do
    case Beamcore.MCP.Config.toggle_enabled() do
      :ok -> Beamcore.MCP.Config.snapshot()
      _ -> snapshot
    end
  end

  def lines(snapshot) when is_map(snapshot) do
    enabled? = Map.get(snapshot, :enabled?, false)
    server_count = Map.get(snapshot, :server_count, 0)
    status = if enabled?, do: "armed", else: "standby"
    status_style = if enabled?, do: Theme.style(:status_hot), else: Theme.style(:muted)

    [
      %Line{
        spans: [
          %Span{content: "  external tools  ", style: Theme.style(:muted)},
          %Span{content: status, style: status_style},
          %Span{content: "  //  servers ", style: Theme.style(:subtle)},
          %Span{content: Integer.to_string(server_count), style: Theme.style(:accent)}
        ]
      },
      %Line{
        spans: [
          %Span{content: "  ", style: Theme.style(:base)},
          %Span{content: "m", style: Theme.style(:accent)},
          %Span{
            content: " toggle MCP config flag  //  no server autostart",
            style: Theme.style(:muted)
          }
        ]
      }
    ]
  end
end
