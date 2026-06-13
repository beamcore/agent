defmodule Beamcore.TUI.Components.Mascot do
  @moduledoc false

  @unicode_frames %{
    idle: [
      "  ◢▣◣  ▱▱▱",
      "  ◢▣◣  ▱▱▱",
      "  ◢▣◣  ▱▱▱",
      "  ◢▣◣  ▱▱▱"
    ],
    thinking: [
      "  ◢▣◣  ·   ",
      "  ◢▣◣  ··  ",
      "  ◢▣◣  ··· ",
      "  ◢▣◣  ····"
    ],
    running: [
      "  ◢▣◣  ▱▱▱",
      "  ◢▣◣  ▰▱▱",
      "  ◢▣◣  ▰▰▱",
      "  ◢▣◣  ▰▰▰"
    ],
    tool_running: [
      "  ◢▣◣    ⚙",
      "  ◢▣◣    ⚙",
      "  ◢▣◣  ⚙  ",
      "  ◢▣◣  ⚙  "
    ],
    error: [
      "  ◢▣◣  !   ",
      "  ◢▣◣  ×   "
    ]
  }

  @ascii_frames %{
    idle: ["o[b]o ...", "o[b]o ..."],
    thinking: ["[b] scan .  ", "[b] scan .. ", "[b] scan ..."],
    running: ["o[b]o ...", "o[b]o #..", "o[b]o ##.", "<[b]> ###"],
    tool_running: ["* o[b]>   ", " * o[b]>  ", "  * <[b] "],
    error: ["[!]   ", "[x]   "]
  }

  def frame(status, step, unicode? \\ true) do
    status
    |> frames(unicode?)
    |> at(step)
  end

  defp frames(status, true), do: Map.get(@unicode_frames, normalize(status), @unicode_frames.idle)
  defp frames(status, false), do: Map.get(@ascii_frames, normalize(status), @ascii_frames.idle)

  defp at(frames, step), do: Enum.at(frames, rem(max(step, 0), length(frames)))

  defp normalize(:thinking), do: :thinking
  defp normalize(:local_search), do: :thinking
  defp normalize(:rate_limited), do: :thinking
  defp normalize(:tool_running), do: :tool_running
  defp normalize(:running), do: :running
  defp normalize(:error), do: :error
  defp normalize(_status), do: :idle
end
