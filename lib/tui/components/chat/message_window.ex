defmodule Beamcore.TUI.Components.Chat.MessageWindow do
  @moduledoc false

  @chat_overscan_lines 24
  @max_scan_messages 200

  def visible_message_window(messages, wrap_width, viewport_height, distance_from_bottom) do
    needed =
      max(
        @max_scan_messages,
        (distance_from_bottom || 0) + viewport_height + @chat_overscan_lines
      )

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

  def estimated_message_height(%{role: :tool, content: content}, width),
    do: estimated_text_height(content, width) + 2

  def estimated_message_height(%{role: :eeva_preview, content: content}, _width),
    do: newline_count(content) + 2

  def estimated_message_height(%{content: content}, width),
    do: estimated_text_height(content, width) + 2

  def estimated_message_height(_message, _width), do: 2

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
