defmodule Beamcore.Agent.TUI.Render do
  @moduledoc """
  Render composition for the primary TUI.
  """

  alias Beamcore.Agent.TUI.Components.{Activity, Chat, Help, Input, Mascot, StatusBar}
  alias Beamcore.Agent.TUI.{Layout, Theme}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Paragraph, SlashCommands}

  def render(state) do
    {width, height} = ExRatatui.terminal_size()
    area = %Rect{x: 0, y: 0, width: width, height: height}
    areas = Layout.areas(area)

    widgets =
      case areas.mode do
        :tiny -> tiny(state, area)
        :wide -> wide(state, areas)
        :medium -> medium(state, areas)
        :narrow -> narrow(state, areas)
      end

    widgets
    |> maybe_activity_details(state, area)
    |> maybe_help(state, area)
    |> maybe_commands(state, area)
  end

  defp tiny(state, area) do
    [
      {%Paragraph{
         text:
           "#{Mascot.portrait(:waiting_confirmation, state.spinner_step, state.unicode?)}\n\nBeamcore.Agent\n\nTerminal is too small for the full TUI.\nEnlarge it or use the plain emergency fallback.",
         style: Theme.style(:error),
         alignment: :center,
         wrap: true
       }, area}
    ]
  end

  defp wide(state, areas) do
    [
      {header(state), areas.header},
      {Chat.widget(state, areas.chat), areas.chat},
      {Activity.widget(state, :sidebar), areas.activity},
      {Input.widget(state), areas.input},
      {StatusBar.widget(state, :wide), areas.status}
    ]
  end

  defp medium(state, areas) do
    [
      {header(state), areas.header},
      {Chat.widget(state, areas.chat), areas.chat},
      {Activity.widget(state, :strip), areas.activity},
      {Input.widget(state), areas.input},
      {StatusBar.widget(state, :medium), areas.status}
    ]
  end

  defp narrow(state, areas) do
    [
      {header(state), areas.header},
      {Chat.widget(state, areas.chat), areas.chat},
      {Input.widget(state), areas.input},
      {StatusBar.widget(state, :narrow), areas.status}
    ]
  end

  defp header(state) do
    yolo = if Beamcore.Agent.TUI.State.yolo?(state.session), do: "  YOLO", else: ""

    %Paragraph{
      text: "BEAMCORE.AGENT#{yolo}  // live tools  // /help",
      style: Theme.style(:title)
    }
  end

  defp maybe_activity_details(widgets, %{show_activity_details: true} = state, area),
    do: widgets ++ [{Activity.details_widget(state), area}]

  defp maybe_activity_details(widgets, _state, _area), do: widgets

  defp maybe_help(widgets, %{show_help: true}, area), do: widgets ++ [{Help.widget(), area}]
  defp maybe_help(widgets, _state, _area), do: widgets

  defp maybe_commands(widgets, state, area) do
    if state.show_commands and state.command_matches != [] do
      widgets ++
        SlashCommands.render_autocomplete(state.command_matches,
          area: area,
          selected: state.command_selected,
          percent_width: 46,
          percent_height: 34,
          highlight_style: Theme.style(:accent),
          style: Theme.style(:panel)
        )
    else
      widgets
    end
  end
end
