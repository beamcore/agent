defmodule Beamcore.TUI.Render do
  @moduledoc """
  Render composition for the primary TUI.
  """

  alias Beamcore.TUI.Components.{Chat, Help, Input, System, StatusBar}
  alias Beamcore.TUI.{Layout, Theme}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, List, Paragraph, Popup, SlashCommands}

  @chat_cache_key {__MODULE__, :chat_widget_cache}

  def render(%{screen_type: :system} = state, frame) do
    area = %Rect{x: 0, y: 0, width: max(frame.width, 1), height: max(frame.height, 1)}
    status_h = 1
    content_h = max(area.height - status_h, 1)
    content = %{area | height: content_h}
    status = %{area | y: content_h, height: status_h}
    lines = System.render_text(state, max(content.width - 4, 1), content.height)

    [
      {%Paragraph{text: lines, style: Theme.style(:base), wrap: false}, content},
      {StatusBar.widget(state, status.width), status}
    ]
  end

  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: max(frame.width, 1), height: max(frame.height, 1)}
    areas = Layout.areas(area, state.screen_type)

    widgets =
      case areas.mode do
        :tiny -> tiny(state, area)
        :wide -> wide(state, areas)
        :medium -> medium(state, areas)
        :narrow -> narrow(state, areas)
      end

    widgets
    |> maybe_help(state, area)
    |> maybe_commands(state, area)
    |> maybe_file_finder(state, area)
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

  defp wide(state, areas), do: standard_widgets(state, areas)
  defp medium(state, areas), do: standard_widgets(state, areas)
  defp narrow(state, areas), do: standard_widgets(state, areas)

  defp standard_widgets(state, areas) do
    [
      {cached_chat_widget(state, areas.chat), areas.chat},
      {Input.widget(state), areas.input},
      {StatusBar.widget(state, areas.status.width), areas.status}
    ]
  end

  defp cached_chat_widget(state, %Rect{} = area) do
    key = chat_cache_key(state, area)

    case Process.get(@chat_cache_key) do
      {^key, widget} ->
        widget

      _ ->
        widget = Chat.widget(state, area)
        Process.put(@chat_cache_key, {key, widget})
        widget
    end
  end

  defp chat_cache_key(state, %Rect{} = area) do
    {
      state.screen_type,
      area.width,
      area.height,
      state.scroll_offset,
      state.chat_viewport_height,
      Theme.current_theme(),
      :erlang.phash2({
        state.messages,
        state.collapsed_blocks,
        state.memory_total,
        state.notice
      })
    }
  end

  defp maybe_help(widgets, %{show_help: true}, area), do: widgets ++ [{Help.widget(), area}]
  defp maybe_help(widgets, _state, _area), do: widgets

  defp maybe_commands(widgets, state, area) do
    cond do
      state.show_theme_picker ->
        widgets ++ [render_theme_popup(state, area)]

      state.show_commands and state.command_matches != [] ->
        widgets ++
          SlashCommands.render_autocomplete(state.command_matches,
            area: area,
            selected: state.command_selected,
            percent_width: 46,
            percent_height: 34,
            highlight_style: Theme.style(:accent),
            style: Theme.style(:panel)
          )

      true ->
        widgets
    end
  end

  defp render_theme_popup(state, area) do
    current = Theme.current_theme()

    items =
      Theme.list_themes()
      |> Enum.sort()
      |> Enum.map(fn name ->
        if name == current, do: "#{name}  (current)", else: "#{name}"
      end)

    list = %List{
      items: items,
      selected: state.command_selected,
      highlight_style: Theme.style(:accent),
      style: Theme.style(:panel)
    }

    popup = %Popup{
      content: list,
      block: %Block{
        title: "Themes",
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:border_hot)
      },
      percent_width: 28,
      percent_height: 50
    }

    {popup, area}
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
    list = %List{
      items: state.file_finder_results,
      selected: state.file_finder_selected,
      highlight_style: Theme.style(:accent),
      style: Theme.style(:panel)
    }

    popup = %Popup{
      content: list,
      block: %Block{
        title: "Files: @#{state.file_finder_query}",
        borders: [:all],
        border_type: :rounded
      },
      percent_width: 50,
      percent_height: 40
    }

    [{popup, area}]
  end
end
