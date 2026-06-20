defmodule Beamcore.TUI.Components.System do
  @moduledoc false

  alias Beamcore.TUI.Components.{Providers, System.Stats}
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
    sep = String.duplicate("─", max(width - 6, 4))

    stats_lines = Stats.render(width)
    provider_items = Providers.render_items(system.providers, width)

    [%Line{spans: [%Span{content: ""}]}] ++
      stats_lines ++
      [
        %Line{spans: [%Span{content: ""}]},
        %Line{spans: [%Span{content: "  Providers", style: accent}]},
        %Line{spans: [%Span{content: "  #{sep}", style: subtle}]}
      ] ++
      provider_items
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
