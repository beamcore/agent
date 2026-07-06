defmodule Beamcore.TUI.Layout do
  @moduledoc """
  Adaptive layout modes for the terminal UI.
  """

  alias ExRatatui.Layout, as: RatLayout
  alias ExRatatui.Layout.Rect

  def mode(width, height) when width < 44 or height < 10, do: :tiny
  def mode(width, _height) when width < 88, do: :narrow
  def mode(width, _height) when width < 120, do: :medium
  def mode(_width, _height), do: :wide

  def areas(%Rect{} = area, screen_type \\ :agent) do
    case mode(area.width, area.height) do
      :tiny ->
        %{mode: :tiny, screen: area}

      resolved ->
        [chat, input] = shell(area, 0, input_height(area.height))
        mode = if screen_type == :chat, do: :narrow, else: resolved
        %{mode: mode, chat: chat, input: input}
    end
  end

  def chat_viewport_height(%Rect{} = area, screen_type \\ :agent) do
    case areas(area, screen_type) do
      %{chat: %Rect{height: height}} -> max(height, 0)
      _ -> 0
    end
  end

  defp shell(area, header_height, input_height) do
    parts =
      RatLayout.split(area, :vertical, [
        {:length, header_height},
        {:min, 8},
        {:length, input_height}
      ])

    # When header_height is 0, the first element is a zero-height rect.
    # We skip it and return [body, input]. The status line is no longer part
    # of the body — the shell owns the footer (tab strip + status line).
    case parts do
      [header | rest] when header.height == 0 -> rest
      other -> other
    end
  end

  defp input_height(height) when height < 18, do: 3
  defp input_height(height) when height < 26, do: 4
  defp input_height(_height), do: 5
end
