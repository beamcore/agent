defmodule Beamcore.TUI.Components.Mascot do
  @moduledoc false

  @unicode_frames %{
    idle: [
      "ᕕ(◢▣◣)ᕗ ▱▱▱",
      "ᕕ(◢▣◣)ᕗ ▱▱▱",
      "ᕕ(◢▣◣)ᕗ ▱▱▱",
      "ᕕ(◢▣◣)ᕗ ▱▱▱"
    ],
    thinking: [
      "  ◢▣◣  ·   ",
      "  ◢▣◣  ··  ",
      "  ◢▣◣  ··· ",
      "  ◢▣◣  ····"
    ],
    running: [
      "ᕕ(◢▣◣)ᕗ ▱▱▱",
      "ᕙ(◢▣◣)ᕗ ▰▱▱",
      "ᕕ(◢▣◣)ᕗ ▰▰▱",
      "ᕙ(◢▣◣)ᕘ ▰▰▰"
    ],
    tool_running: [
      "ᕕ(◢▣◣)ᕗ   ⚙",
      "ᕕ(◢▣◣)ᕗ   ⚙",
      "ᕙ(◢▣◣)ᕘ ⚙  ",
      "ᕙ(◢▣◣)ᕘ ⚙  "
    ],
    generating: [
      "ᕕ(◢▣◣)ᕗ ▱ img",
      "ᕙ(◢▣◣)ᕗ ▰ img",
      "ᕕ(◢▣◣)ᕗ ▰ img",
      "ᕙ(◢▣◣)ᕘ ▰ img"
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
    generating: ["[b] img .  ", "[b] img .. ", "[b] img ..."],
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
  defp normalize(:tool_running), do: :tool_running
  defp normalize(:generating), do: :generating
  defp normalize(:running), do: :running
  defp normalize(:error), do: :error
  defp normalize(_status), do: :idle
end
