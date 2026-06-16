defmodule Beamcore.TUI.Components.Chat do
  @moduledoc false

  alias Beamcore.TUI.Components.{Chat.DiffRenderer, Chat.SyntaxHighlight, EmptyState}
  alias Beamcore.TUI.{Theme, Wrap}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, WidgetList}

  @chat_overscan_lines 24
  @max_scan_messages 200

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

  def visible_message_window(messages, wrap_width, viewport_height, distance_from_bottom) do
    needed = max(@max_scan_messages, (distance_from_bottom || 0) + viewport_height + @chat_overscan_lines)
    trimmed = Enum.take(messages, -min(needed, length(messages)))

    visible_message_window(
      trimmed,
      wrap_width,
      viewport_height,
      distance_from_bottom,
      @chat_overscan_lines
    )
  end

  def visible_message_window(
        messages,
        wrap_width,
        viewport_height,
        distance_from_bottom,
        overscan
      )
      when is_list(messages) and (distance_from_bottom == 0 or is_nil(distance_from_bottom)) do
    body_width = max(wrap_width - 2, 10)
    viewport_height = max(viewport_height, 1)
    overscan = max(overscan || 0, 0)
    upper = viewport_height + overscan

    {selected, _height} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn message, {selected, height} ->
        message_height = estimated_message_height(message, body_width)
        next_height = height + message_height

        if height <= upper do
          {:cont, {[message | selected], next_height}}
        else
          {:halt, {selected, height}}
        end
      end)

    {selected, 0, 0}
  end

  def visible_message_window(
        messages,
        wrap_width,
        viewport_height,
        distance_from_bottom,
        overscan
      )
      when is_list(messages) do
    body_width = max(wrap_width - 2, 10)
    viewport_height = max(viewport_height, 1)
    distance_from_bottom = max(distance_from_bottom || 0, 0)
    overscan = max(overscan || 0, 0)
    lower = max(distance_from_bottom - overscan, 0)
    upper = distance_from_bottom + viewport_height + overscan

    {selected, bottom_spacer, total_height} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, 0}, fn message, {selected, spacer, cursor} ->
        height = estimated_message_height(message, body_width)
        next_cursor = cursor + height

        cond do
          cursor > upper and selected != [] ->
            {:halt, {selected, spacer, cursor}}

          next_cursor < lower ->
            {:cont, {selected, next_cursor, next_cursor}}

          next_cursor >= lower and cursor <= upper ->
            {:cont, {[message | selected], spacer, next_cursor}}

          true ->
            {:cont, {selected, spacer, next_cursor}}
        end
      end)

    if selected == [] and messages != [] and distance_from_bottom > 0 do
      clamped_offset = max(total_height - viewport_height, 0)
      visible_message_window(messages, wrap_width, viewport_height, clamped_offset, overscan)
    else
      {selected, bottom_spacer, distance_from_bottom}
    end
  end

  defp message_items(%{messages: []} = state, wrap_width) do
    text = state |> EmptyState.text() |> Wrap.lines(wrap_width) |> Enum.join("\n")
    [{EmptyState.widget(text), max(5, line_count(text))}]
  end

  defp message_items(%{messages: messages}, wrap_width) do
    Enum.flat_map(messages, fn
      %{role: :user, content: content} ->
        bubble("You", content, Theme.style(:user), wrap_width, :plain)

      %{role: :assistant, content: content} ->
        bubble("Agent", content, Theme.style(:accent), wrap_width, :markdown)

      %{role: :tool, content: content} ->
        tool_bubble("Modify File", content, wrap_width)

      %{role: :error, content: content} ->
        bubble("Error", content, Theme.style(:error), wrap_width, :plain)

      %{role: :local, content: content} ->
        bubble("Helper", content, Theme.style(:status_hot), wrap_width, :plain)

      %{role: :eeva_preview, content: content} ->
        eeva_preview_bubble(content, wrap_width)

      %{role: :memory, content: content} ->
        bubble("Memory", content, Theme.style(:checkpoint), wrap_width, :plain)

      %{role: :checkpoint, content: content} ->
        bubble("Checkpoint", content, Theme.style(:checkpoint), wrap_width, :plain)

      %{content: content} ->
        bubble("System", content, Theme.style(:muted), wrap_width, :plain)
    end)
  end

  defp visible_message_state(%{messages: []} = state, _wrap_width, _viewport_height),
    do: {state, 0}

  defp visible_message_state(state, wrap_width, viewport_height) do
    {messages, bottom_spacer, effective_offset} =
      visible_message_window(state.messages, wrap_width, viewport_height, state.scroll_offset)

    {%{state | messages: messages} |> Map.put(:bottom_spacer_height, bottom_spacer),
     effective_offset}
  end

  defp append_bottom_spacer(items, height) when is_integer(height) and height > 0 do
    items ++ [{%Paragraph{text: "", style: Theme.style(:subtle), wrap: false}, height}]
  end

  defp append_bottom_spacer(items, _height), do: items

  defp tool_bubble(label, content, wrap_width),
    do: DiffRenderer.render(label, content, wrap_width)

  defp bubble(label, content, style, wrap_width, kind) do
    body_width = max(wrap_width - 2, 10)

    lines =
      case kind do
        :markdown -> Wrap.markdown_lines(to_string(content), body_width)
        :plain -> Wrap.lines(to_string(content), body_width)
      end

    prefix = label_prefix(label)
    card = card_text(prefix, lines, wrap_width)

    [
      {%Paragraph{text: card, style: style, wrap: false}, line_count(card)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end

  defp label_prefix("You"), do: ">"
  defp label_prefix("Agent"), do: "*"
  defp label_prefix("Tool"), do: "»"
  defp label_prefix("Modify File"), do: "»"
  defp label_prefix("Error"), do: "!"
  defp label_prefix("System"), do: "·"
  defp label_prefix("Helper"), do: "·"
  defp label_prefix("Memory"), do: "◆"
  defp label_prefix("Checkpoint"), do: "◇"
  defp label_prefix(label), do: label |> to_string() |> String.slice(0, 1)

  defp card_text(prefix, lines, wrap_width) do
    body =
      lines
      |> Enum.flat_map(&split_preserving_width(&1, max(wrap_width - 2, 10)))
      |> Enum.map(&"  #{&1}")

    trimmed_body =
      body
      |> Enum.join("\n")
      |> String.trim()

    ["#{prefix} " <> trimmed_body]
    |> Enum.join("\n")
  end

  defp split_preserving_width(line, width), do: Wrap.lines(to_string(line), width)

  defp line_count(text), do: text |> to_string() |> String.split("\n") |> length()

  defp content_width(%Rect{width: width}), do: max(width - 4, 12)

  defp estimated_message_height(%{role: :tool, content: content}, width),
    do: estimated_text_height(content, width) + 2

  defp estimated_message_height(%{role: :eeva_preview, content: content}, _width),
    do: newline_count(content) + 2

  defp estimated_message_height(%{content: content}, width),
    do: estimated_text_height(content, width) + 2

  defp estimated_message_height(_message, _width), do: 2

  defp estimated_text_height(content, width) do
    text = to_string(content || "")
    chars = String.length(text)
    explicit_lines = newline_count(text)
    max(explicit_lines, div(chars, max(width, 1)) + 1)
  end

  defp newline_count(text) do
    text
    |> to_string()
    |> String.split("\n", trim: false)
    |> length()
  end

  defp scroll_offset(items, %Rect{height: height}, distance_from_bottom) do
    content_height = Enum.reduce(items, 0, fn {_, h}, acc -> acc + h end)
    viewport_height = max(height - 2, 1)
    max_scroll = max(content_height - viewport_height, 0)
    max(max_scroll - distance_from_bottom, 0)
  end

  defp eeva_preview_bubble(code, wrap_width) do
    first_line = %Line{
      spans: [%Span{content: "\u26A1 EEVA", style: Theme.style(:accent)}]
    }

    max_len = max(wrap_width - 4, 10)

    code_lines =
      code
      |> to_string()
      |> String.split(~r/\r?\n/)
      |> Enum.map(&SyntaxHighlight.highlight_line(&1, max_len))

    all_lines = [first_line | code_lines]

    [
      {%Paragraph{text: all_lines, style: Theme.style(:muted), wrap: false}, length(all_lines)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end
end
