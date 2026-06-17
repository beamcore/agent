defmodule Beamcore.TUI.Components.Chat do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.{Bubbles, MessageWindow}
  alias Beamcore.TUI.Components.EmptyState
  alias Beamcore.TUI.{Theme, Wrap}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, WidgetList}

  defdelegate visible_message_window(messages, wrap_width, viewport_height, distance_from_bottom),
    to: MessageWindow

  def widget(state, %Rect{} = area) do
    wrap_width = content_width(area)
    viewport_height = max(area.height - 2, 1)

    {message_state, effective_scroll_offset} =
      visible_message_state(state, wrap_width, viewport_height)

    items =
      message_state
      |> message_items(wrap_width)
      |> append_bottom_spacer(Map.get(message_state, :bottom_spacer_height, 0))

    %WidgetList{
      items: items,
      scroll_offset: scroll_offset(items, area, effective_scroll_offset),
      block: %Block{
        borders: [],
        padding: {0, 0, 0, 0}
      }
    }
  end

  def render_message_lines(label, content, width) do
    [label | Wrap.lines(content, width)]
  end

  defp message_items(%{messages: []} = state, wrap_width) do
    text = state |> EmptyState.text() |> Wrap.lines(wrap_width) |> Enum.join("\n")
    [{EmptyState.widget(text), max(5, Bubbles.line_count(text))}]
  end

  defp message_items(%{messages: messages}, wrap_width) do
    Enum.flat_map(messages, fn
      %{role: :user, content: content} ->
        Bubbles.bubble("You", content, Theme.style(:user), wrap_width, :plain)

      %{role: :assistant, content: content} ->
        Bubbles.bubble("Agent", content, Theme.style(:accent), wrap_width, :markdown)

      %{role: :tool, content: content} ->
        Bubbles.tool_bubble("Modify File", content, wrap_width)

      %{role: :error, content: content} ->
        Bubbles.bubble("Error", content, Theme.style(:error), wrap_width, :plain)

      %{role: :local, content: content} ->
        Bubbles.bubble("Helper", content, Theme.style(:status_hot), wrap_width, :plain)

      %{role: :eeva_preview, content: content} ->
        Bubbles.eeva_preview_bubble(content, wrap_width)

      %{role: :memory, content: content} ->
        Bubbles.bubble("Memory", content, Theme.style(:checkpoint), wrap_width, :plain)

      %{role: :thinking, content: content} ->
        Bubbles.bubble("Thinking", content, Theme.style(:thinking), wrap_width, :plain)

      %{role: :checkpoint, content: content} ->
        Bubbles.bubble("Checkpoint", content, Theme.style(:checkpoint), wrap_width, :plain)

      %{content: content} ->
        Bubbles.bubble("System", content, Theme.style(:muted), wrap_width, :plain)
    end)
  end

  defp visible_message_state(%{messages: []} = state, _wrap_width, _viewport_height),
    do: {state, 0}

  defp visible_message_state(state, wrap_width, viewport_height) do
    {messages, bottom_spacer, effective_offset} =
      MessageWindow.visible_message_window(
        state.messages,
        wrap_width,
        viewport_height,
        state.scroll_offset
      )

    {%{state | messages: messages} |> Map.put(:bottom_spacer_height, bottom_spacer),
     effective_offset}
  end

  defp append_bottom_spacer(items, height) when is_integer(height) and height > 0 do
    items ++ [{%Paragraph{text: "", style: Theme.style(:subtle), wrap: false}, height}]
  end

  defp append_bottom_spacer(items, _height), do: items

  defp scroll_offset(items, %Rect{height: height}, distance_from_bottom) do
    content_height = Enum.reduce(items, 0, fn {_, h}, acc -> acc + h end)
    viewport_height = max(height - 2, 1)
    max_scroll = max(content_height - viewport_height, 0)
    max(max_scroll - distance_from_bottom, 0)
  end

  defp content_width(%Rect{width: width}), do: max(width - 4, 12)
end
