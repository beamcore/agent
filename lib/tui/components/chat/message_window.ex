defmodule Beamcore.TUI.Components.Chat.MessageWindow do
  @moduledoc false

  @chat_overscan_lines 24
  @max_scan_messages 200
  @collapsed_height 4

  def visible_message_window(messages, wrap_width, viewport_height, distance_from_bottom) do
    {indexed, bottom_spacer, offset} =
      visible_message_window_indexed(messages, wrap_width, viewport_height, distance_from_bottom)

    {Enum.map(indexed, fn {msg, _idx} -> msg end), bottom_spacer, offset}
  end

  def visible_message_window_indexed(
        messages,
        wrap_width,
        viewport_height,
        distance_from_bottom,
        collapsed_blocks \\ %{}
      ) do
    needed =
      max(
        @max_scan_messages,
        (distance_from_bottom || 0) + viewport_height + @chat_overscan_lines
      )

    trimmed = Enum.take(messages, -min(needed, length(messages)))
    start_idx = max(length(messages) - length(trimmed), 0)

    visible_message_window_impl(
      trimmed,
      wrap_width,
      viewport_height,
      distance_from_bottom,
      @chat_overscan_lines,
      start_idx,
      collapsed_blocks
    )
  end

  defp visible_message_window_impl(
         messages,
         wrap_width,
         viewport_height,
         distance_from_bottom,
         overscan,
         start_idx,
         collapsed_blocks
       )
       when is_list(messages) and (distance_from_bottom == 0 or is_nil(distance_from_bottom)) do
    body_width = max(wrap_width - 2, 10)
    viewport_height = max(viewport_height, 1)
    overscan = max(overscan || 0, 0)
    upper = viewport_height + overscan
    len = length(messages)
    init_idx = start_idx + len - 1

    {selected, _height, _orig_idx} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, init_idx}, fn message, {selected, height, orig_idx} ->
        message_height = estimated_message_height(message, body_width, collapsed_blocks, orig_idx)
        next_height = height + message_height

        if height <= upper do
          {:cont, {[{message, orig_idx} | selected], next_height, orig_idx - 1}}
        else
          {:halt, {selected, height, orig_idx}}
        end
      end)

    {selected, 0, 0}
  end

  defp visible_message_window_impl(
         messages,
         wrap_width,
         viewport_height,
         distance_from_bottom,
         overscan,
         start_idx,
         collapsed_blocks
       )
       when is_list(messages) do
    body_width = max(wrap_width - 2, 10)
    viewport_height = max(viewport_height, 1)
    distance_from_bottom = max(distance_from_bottom || 0, 0)
    overscan = max(overscan || 0, 0)
    lower = max(distance_from_bottom - overscan, 0)
    upper = distance_from_bottom + viewport_height + overscan
    len = length(messages)
    init_idx = start_idx + len - 1

    {selected, bottom_spacer, total_height, _orig_idx} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, 0, init_idx}, fn message,
                                                    {selected, spacer, cursor, orig_idx} ->
        height = estimated_message_height(message, body_width, collapsed_blocks, orig_idx)
        next_cursor = cursor + height

        cond do
          cursor > upper and selected != [] ->
            {:halt, {selected, spacer, cursor, orig_idx}}

          next_cursor < lower ->
            {:cont, {selected, next_cursor, next_cursor, orig_idx - 1}}

          next_cursor >= lower and cursor <= upper ->
            {:cont, {[{message, orig_idx} | selected], spacer, next_cursor, orig_idx - 1}}

          true ->
            {:cont, {selected, spacer, next_cursor, orig_idx - 1}}
        end
      end)

    if selected == [] and messages != [] and distance_from_bottom > 0 do
      clamped_offset = max(total_height - viewport_height, 0)

      visible_message_window_impl(
        messages,
        wrap_width,
        viewport_height,
        clamped_offset,
        overscan,
        start_idx,
        collapsed_blocks
      )
    else
      {selected, bottom_spacer, distance_from_bottom}
    end
  end

  def estimated_message_height(message, width, collapsed_blocks \\ %{}, orig_idx \\ 0)

  def estimated_message_height(%{role: :eeva_preview} = msg, _width, collapsed_blocks, orig_idx) do
    if collapsed?(collapsed_blocks, orig_idx),
      do: @collapsed_height,
      else: newline_count(msg.content) + 2
  end

  def estimated_message_height(%{role: :tool, content: content}, width, _cb, _idx),
    do: estimated_text_height(content, width) + 2

  def estimated_message_height(%{content: content}, width, _cb, _idx),
    do: estimated_text_height(content, width) + 2

  def estimated_message_height(_message, _width, _cb, _idx), do: 2

  defp collapsed?(collapsed_blocks, orig_idx) do
    MapSet.member?(Map.get(collapsed_blocks, orig_idx, MapSet.new()), 0)
  end

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
end
