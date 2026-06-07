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

      _ when screen_type == :chat ->
        [chat, input, status] = shell(area, 0, input_height(area.height))
        %{mode: :narrow, chat: chat, input: input, status: status}

      :wide ->
        [body, input, status] = shell(area, 0, input_height(area.height))

        [chat, activity] =
          RatLayout.split(body, :horizontal, [{:percentage, 74}, {:percentage, 26}])

        %{
          mode: :wide,
          chat: chat,
          activity: activity,
          input: input,
          status: status
        }

      :medium ->
        [chat, activity, input, status] =
          RatLayout.split(area, :vertical, [
            {:min, 8},
            {:length, compact_activity_height(area.height)},
            {:length, input_height(area.height)},
            {:length, 1}
          ])

        %{
          mode: :medium,
          chat: chat,
          activity: activity,
          input: input,
          status: status
        }

      :narrow ->
        [chat, input, status] = shell(area, 0, input_height(area.height))
        %{mode: :narrow, chat: chat, input: input, status: status}
    end
  end

  defp shell(area, header_height, input_height) do
    parts =
      RatLayout.split(area, :vertical, [
        {:length, header_height},
        {:min, 8},
        {:length, input_height},
        {:length, 1}
      ])

    # When header_height is 0, the first element is a zero-height rect
    # We want to skip it and return [body, input, status]
    case parts do
      [header | rest] when header.height == 0 -> rest
      other -> other
    end
  end

  defp input_height(height) when height < 18, do: 3
  defp input_height(height) when height < 26, do: 4
  defp input_height(_height), do: 5

  defp compact_activity_height(height) when height < 24, do: 3
  defp compact_activity_height(_height), do: 4
end
