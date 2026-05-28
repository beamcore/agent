defmodule Beamcore.TUI.Components.Activity do
  @moduledoc false

  alias Beamcore.TUI.{Theme, Wrap}
  alias ExRatatui.Widgets.{Block, Paragraph, Popup, WidgetList}

  def widget(state, variant \\ :sidebar) do
    items =
      state.activity
      |> Enum.reverse()
      |> Enum.take(limit(variant))
      |> Enum.flat_map(&event_items(&1, variant, state.spinner_step))

    items =
      if items == [] do
        [{%Paragraph{text: empty_text(variant), style: Theme.style(:muted), wrap: true}, 2}]
      else
        items
      end

    %WidgetList{
      items: items,
      scroll_offset: 0,
      block: %Block{
        title: title(variant),
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:border),
        padding: {1, 1, 0, 0}
      }
    }
  end

  def details_widget(state) do
    selected = Enum.at(state.activity, state.selected_activity) || List.first(state.activity)

    %Popup{
      content: %Paragraph{text: details_text(selected), style: Theme.style(:panel), wrap: true},
      block: %Block{
        title: "Tool details",
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

  defp event_items(event, :strip, step) do
    [
      {%Paragraph{
         text: Wrap.truncate_line("#{marker(event, step)} #{event.label}", 96),
         style: style(event.status),
         wrap: true
       }, 1}
    ]
  end

  defp event_items(event, _variant, step) do
    [
      {%Paragraph{
         text: Wrap.truncate_line("#{marker(event, step)} #{event.label}", 72),
         style: style(event.status),
         wrap: true
       }, 1},
      {%Paragraph{
         text: Wrap.truncate_line(event.summary || "", 96),
         style: Theme.style(:subtitle),
         wrap: true
       }, summary_height(event.summary)}
    ]
    |> Enum.reject(fn {_widget, height} -> height == 0 end)
  end

  defp details_text(nil), do: "No tool activity yet."

  defp details_text(event) do
    [
      "#{status_prefix(event.status)} #{event.label}",
      "",
      field("tool", event.name),
      field("state", event.status),
      field("target", event.target || "none"),
      field("summary", event.summary || "none"),
      field("result", event.result || "none")
    ]
    |> Enum.join("\n")
  end

  defp field(label, value), do: "#{label}: #{value}"

  defp title(:strip), do: "Activity · tools"
  defp title(_variant), do: "Activity · tools"
  defp empty_text(:strip), do: "◇ Tools pulse here."

  defp empty_text(_variant),
    do: "◇ Tool calls, blocked attempts, validation, and images appear here."

  defp limit(:strip), do: 4
  defp limit(_variant), do: 14
  defp summary_height(nil), do: 0
  defp summary_height(""), do: 0
  defp summary_height(text), do: min(3, length(String.split(text, "\n")))
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
end
