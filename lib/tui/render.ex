defmodule Beamcore.TUI.Render do
  @moduledoc """
  Render composition for the primary TUI.
  """

  alias Beamcore.TUI.Components.{Activity, Chat, Help, Input, StatusBar}
  alias Beamcore.TUI.{Layout, Theme, State}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Paragraph, SlashCommands, Block, List, Popup}

  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    areas = Layout.areas(area, state.screen_type)

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
    |> maybe_file_finder(state, area)
    |> maybe_provider_selector(state, area)
  end

  defp tiny(_state, area) do
    [
      {%Paragraph{
         text:
           "Beamcore.Agent\n\nTerminal is too small for the full TUI.\nEnlarge it or use the plain emergency fallback.",
         style: Theme.style(:error),
         alignment: :center,
         wrap: true
       }, area}
    ]
  end

  defp wide(state, areas) do
    [
      {Chat.widget(state, areas.chat), areas.chat},
      {Activity.widget(state, {:sidebar, areas.activity}), areas.activity},
      {Input.widget(state), areas.input},
      {StatusBar.widget(state, areas.status.width), areas.status}
    ]
  end

  defp medium(state, areas) do
    [
      {Chat.widget(state, areas.chat), areas.chat},
      {Activity.widget(state, {:strip, areas.activity}), areas.activity},
      {Input.widget(state), areas.input},
      {StatusBar.widget(state, areas.status.width), areas.status}
    ]
  end

  defp narrow(state, areas) do
    [
      {Chat.widget(state, areas.chat), areas.chat},
      {Input.widget(state), areas.input},
      {StatusBar.widget(state, areas.status.width), areas.status}
    ]
  end

  defp maybe_activity_details(widgets, %{show_activity_details: true} = state, area),
    do: widgets ++ [{Activity.details_widget(state, area), area}]

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

  defp maybe_file_finder(
         widgets,
         %{file_finder_active?: true, file_finder_results: results} = state,
         area
       )
       when results != [] do
    widgets ++ render_file_finder(state, area)
  end

  defp maybe_file_finder(widgets, _state, _area), do: widgets

  defp render_file_finder(state, area) do
    results = state.file_finder_results
    selected = state.file_finder_selected
    query = state.file_finder_query

    list = %List{
      items: results,
      selected: selected,
      highlight_style: Theme.style(:accent),
      style: Theme.style(:panel)
    }

    popup = %Popup{
      content: list,
      block: %Block{
        title: "Files: @#{query}",
        borders: [:all],
        border_type: :rounded
      },
      percent_width: 50,
      percent_height: 40
    }

    [{popup, area}]
  end

  defp maybe_provider_selector(widgets, %{provider_selector_active?: true} = state, area) do
    widgets ++ render_provider_selector(state, area)
  end

  defp maybe_provider_selector(widgets, _state, _area), do: widgets

  defp render_provider_selector(state, area) do
    active_provider = State.provider(state.session)

    formatted_items =
      Enum.map(state.provider_selector_results, &State.format_provider_item(&1, active_provider))

    list = %List{
      items: formatted_items,
      selected: state.provider_selector_selected,
      highlight_style: Theme.style(:accent),
      style: Theme.style(:panel)
    }

    popup = %Popup{
      content: list,
      block: %Block{
        title: "Select API Provider (Ctrl+O to close)",
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:border_hot)
      },
      percent_width: 70,
      percent_height: 35
    }

    [{popup, area}]
  end
end
