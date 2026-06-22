defmodule Beamcore.TUI.Components.System do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System.{Mesh, Stats}
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  defstruct screen_type: :system,
            configure_for: :agent,
            providers: nil

  def new(configure_for \\ :agent) do
    %__MODULE__{
      configure_for: configure_for,
      providers: Providers.new(configure_for)
    }
  end

  def render_text(system, width) do
    accent = Theme.style(:accent)
    subtle = Theme.style(:subtle)

    mesh_lines = Mesh.render(width)
    divider_w = max(76, width - 4)

    mesh_header = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ◆ Mesh Topology  ", style: accent},
          %Span{content: String.duplicate("· ", div(width - 24, 2)), style: subtle}
        ]
      },
      %Line{spans: [%Span{content: ""}]}
    ]

    stats_lines = Stats.render(width)
    provider_items = Providers.render_items(system.providers, width)

    top = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ◆ Beamcore Agent  ", style: accent},
          %Span{content: String.duplicate("· ", div(width - 24, 2)), style: subtle}
        ]
      },
      %Line{spans: [%Span{content: ""}]}
    ]

    divider = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ╰─ ", style: subtle},
          %Span{content: "Providers", style: accent},
          %Span{content: " " <> String.duplicate("─", max(divider_w - 13, 4)), style: subtle}
        ]
      },
      %Line{spans: [%Span{content: ""}]}
    ]

    bottom = [
      %Line{spans: [%Span{content: ""}]},
      %Line{
        spans: [
          %Span{content: " ── ", style: subtle},
          %Span{content: "enter", style: accent},
          %Span{content: " activate  ", style: Theme.style(:muted)},
          %Span{content: "a", style: accent},
          %Span{content: " add  ", style: Theme.style(:muted)},
          %Span{content: "d", style: accent},
          %Span{content: " delete  ", style: Theme.style(:muted)},
          %Span{content: "F1", style: accent},
          %Span{content: " back", style: Theme.style(:muted)}
        ]
      }
    ]

    top ++ stats_lines ++ divider ++ provider_items ++ bottom ++ mesh_header ++ mesh_lines
  end

  def widget(system, area) do
    lines = render_text(system, area.width - 4)
    height = max(length(lines), 1)

    [
      {%Paragraph{text: lines, wrap: false}, height},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:base)}, 1}
    ]
  end

  def mark_dirty(system), do: system

  def handle_event(event, system) do
    case Providers.handle_event(event, system.providers) do
      {:noreply, updated} -> {:noreply, %{system | providers: updated}}
    end
  end
end
