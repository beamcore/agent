defmodule Beamcore.TUI.Components.Activity do
  @moduledoc false

  alias Beamcore.TUI.{State, Theme, Wrap}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Popup, WidgetList}

  def widget(state, variant_or_area \\ :sidebar) do
    {variant, area} =
      case variant_or_area do
        {:sidebar, %Rect{} = area} -> {:sidebar, area}
        {:strip, %Rect{} = area} -> {:strip, area}
        %Rect{} = area -> {:sidebar, area}
        variant when is_atom(variant) -> {variant, nil}
      end

    wrap_width =
      if area do
        max(area.width - 4, 10)
      else
        if variant == :strip, do: 96, else: 72
      end

    items =
      state
      |> State.timeline_items()
      |> Enum.reverse()
      |> Enum.flat_map(&event_items(&1, variant, wrap_width, state.spinner_step))

    items =
      if items == [] do
        [{%Paragraph{text: empty_text(variant), style: Theme.style(:muted), wrap: true}, 2}]
      else
        items
      end

    scroll_offset =
      if area do
        scroll_offset(items, max(area.height - 2, 1), state.activity_scroll_offset)
      else
        0
      end

    %WidgetList{
      items: items,
      scroll_offset: scroll_offset,
      block: %Block{
        title: title(variant),
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:border),
        padding: {1, 1, 0, 0}
      }
    }
  end

  def details_widget(state, %Rect{} = screen_area) do
    popup_width = div(screen_area.width * 64, 100)
    popup_height = div(screen_area.height * 48, 100)
    content_width = max(popup_width - 2, 10)
    content_height = max(popup_height - 2, 2)

    timeline_items = State.timeline_items(state)
    selected = Enum.at(timeline_items, state.selected_activity) || List.first(timeline_items)

    lines =
      details_lines(selected, state.selected_activity, length(timeline_items), content_width)

    items =
      Enum.map(lines, fn line ->
        {%Paragraph{text: line, style: Theme.style(:panel), wrap: false}, 1}
      end)

    max_scroll = max(length(items) - content_height, 0)
    scroll_offset = min(state.details_scroll_offset, max_scroll)

    %Popup{
      content: %WidgetList{
        items: items,
        scroll_offset: scroll_offset,
        block: nil
      },
      block: %Block{
        title: "Timeline details",
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:border_hot),
        padding: {1, 1, 0, 0}
      },
      percent_width: 64,
      percent_height: 48
    }
  end

  def compact_text(state) do
    state.activity
    |> Enum.take(3)
    |> Enum.map(&"#{status_prefix(&1.status)} #{&1.label}")
    |> case do
      [] -> "activity idle"
      values -> Enum.join(values, " · ")
    end
  end

  defp event_items(event, :strip, wrap_width, step) do
    [
      {%Paragraph{
         text: Wrap.truncate_line("#{marker(event, step)} #{event.label}", wrap_width),
         style: style(event.status),
         wrap: false
       }, 1}
    ]
  end

  defp event_items(event, _variant, wrap_width, step) do
    label_text = "#{marker(event, step)} #{event.label}"
    label_lines = Wrap.lines(label_text, wrap_width)
    label_height = length(label_lines)

    args_text = format_tool_args(event[:args])

    {args_lines, args_height} =
      if args_text != "" do
        lines = Wrap.lines(args_text, wrap_width)
        {lines, length(lines)}
      else
        {[], 0}
      end

    summary_text = event.summary || ""

    {summary_lines, summary_height} =
      if summary_text != "" do
        lines = Wrap.lines(summary_text, wrap_width) |> Enum.take(3)
        {lines, length(lines)}
      else
        {[], 0}
      end

    [
      {%Paragraph{
         text: Enum.join(label_lines, "\n"),
         style: style(event.status),
         wrap: false
       }, label_height},
      if(args_height > 0,
        do:
          {%Paragraph{
             text: Enum.join(args_lines, "\n"),
             style: Theme.style(:subtle),
             wrap: false
           }, args_height},
        else: nil
      ),
      if(summary_height > 0,
        do:
          {%Paragraph{
             text: Enum.join(summary_lines, "\n"),
             style: Theme.style(:subtitle),
             wrap: false
           }, summary_height},
        else: nil
      ),
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
    |> Enum.reject(&is_nil/1)
  end

  def details_lines(nil, _index, _total, _width), do: ["No timeline activity yet."]

  def details_lines(event, index, total, width) do
    args_str =
      if is_map(event.args) and map_size(event.args) > 0 do
        inspect(event.args, pretty: true, limit: :infinity, printable_limit: :infinity)
      else
        "none"
      end

    lines = [
      "Timeline item #{min(index + 1, max(total, 1))}/#{max(total, 1)}",
      "#{status_prefix(event.status)} #{event.label}",
      "",
      "time: #{timestamp(event)}",
      "tool: #{event.name}",
      "type: #{event.name}",
      "state: #{event.status}",
      "target: #{event.target || "none"}",
      "branch/checkpoints: #{format_tool_args(event.args || %{})}",
      "summary: #{event.summary || "none"}",
      "arguments:\n#{args_str}",
      "output:\n#{to_string(event.result || "none")}"
    ]

    lines
    |> Enum.flat_map(fn line -> Wrap.lines(line, width) end)
  end

  defp timestamp(%{timestamp_ms: timestamp}) when is_integer(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp timestamp(_event), do: "unknown"

  defp title(:strip), do: "Activity · tools"
  defp title(_variant), do: "Activity · tools"
  defp empty_text(:strip), do: "◇ Tools pulse here."

  defp empty_text(_variant),
    do: "◇ Tool calls, blocked attempts, validation, and images appear here."

  defp status_prefix(:queued), do: "queued"
  defp status_prefix(:running), do: "run"
  defp status_prefix(:done), do: "done"
  defp status_prefix(:blocked), do: "blocked"
  defp status_prefix(:error), do: "error"
  defp status_prefix(status), do: to_string(status)
  defp marker(%{status: :queued}, _step), do: "◇"
  defp marker(%{status: :running}, step), do: Enum.at(["◆", "◇", "◆", "◈"], rem(step, 4))
  defp marker(%{status: :done, name: "image_generation"}, _step), do: "◈"
  defp marker(%{status: :done}, _step), do: "✓"
  defp marker(%{status: :blocked}, _step), do: "!"
  defp marker(%{status: :error}, _step), do: "×"
  defp marker(_event, _step), do: "·"
  defp style(:done), do: Theme.style(:done)
  defp style(:blocked), do: Theme.style(:blocked)
  defp style(:error), do: Theme.style(:error)
  defp style(:running), do: Theme.style(:running)
  defp style(:queued), do: Theme.style(:queued)
  defp style(_), do: Theme.style(:accent)

  defp scroll_offset(items, viewport_height, distance_from_bottom) do
    content_height =
      items
      |> Enum.map(fn {_widget, item_height} -> item_height end)
      |> Enum.sum()

    max_scroll = max(content_height - viewport_height, 0)
    max(max_scroll - distance_from_bottom, 0)
  end

  defp format_tool_args(args) when is_map(args) do
    args
    |> Enum.reject(fn {key, _val} ->
      key_str = key |> to_string() |> String.downcase()

      key_str in ~w(content codecontent replacementcontent targetcontent replacementchunk replacementchunks imagepaths toolaction toolsummary metadata artifactmetadata)
    end)
    |> Enum.map(fn {key, val} ->
      val_str =
        cond do
          is_binary(val) ->
            if String.length(val) > 40 do
              String.slice(val, 0, 37) <> "..."
            else
              val
            end

          is_list(val) or is_map(val) ->
            inspect(val, limit: 3, printable_limit: 40)

          true ->
            to_string(val)
        end

      "#{key}: #{val_str}"
    end)
    |> Enum.join(" · ")
  end

  defp format_tool_args(_), do: ""
end
