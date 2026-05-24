defmodule Beamcore.Agent.TUI.Components.Mascot do
  @moduledoc """
  Tiny terminal-safe BeamCore mascot animation.

  The mascot is text-only so it works in normal terminals, SSH, tmux, and
  screenshots. Header frames are intentionally obvious: if the TUI redraws,
  the little BeamCore runner visibly moves.
  """

  @unicode_portraits %{
    idle: [
      "  ◢▣◣\n ╱█╲\n ╱ ╲",
      "  ◢▣◣\n ╲█╱\n ╱ ╲",
      "  ◢▣◣\n ╱█╲\n ╲ ╱",
      "  ◢▣◣\n ╲█╱\n ╱ ╲"
    ],
    thinking: [
      "  ◢▣◣  ·\n ╱█╲\n ╱ ╲",
      "  ◢▣◣  ··\n ╲█╱\n ╱ ╲",
      "  ◢▣◣  ···\n ╱█╲\n ╲ ╱",
      "  ◢▣◣  ··\n ╲█╱\n ╱ ╲"
    ],
    running: [
      "  ◢▣◣\n ╱█╲_\n ╱ ╲",
      "  ◢▣◣\n _█╱\n  ╱╲",
      "  ◢▣◣\n ╲█╲\n ╱ ╲_",
      "  ◢▣◣\n ╱█╱\n _╱╲"
    ],
    waiting_confirmation: [
      "  ◢▣◣  ?\n ╱█╲\n ╱ ╲",
      "  ◢▣◣  !\n ╲█╱\n ╱ ╲",
      "  ◢▣◣  ?\n ╱█╲\n ╲ ╱",
      "  ◢▣◣  !\n ╲█╱\n ╱ ╲"
    ],
    tool_running: [
      "  ◢▣◣\n ╱█╲_\n ╱ ╲",
      "  ◢▣◣\n _█╱\n  ╱╲",
      "  ◢▣◣\n ╲█╲\n ╱ ╲_",
      "  ◢▣◣\n ╱█╱\n _╱╲"
    ],
    error: [
      "  ◢▣◣  !\n ╱█╲\n ╱ ╲",
      "  ◢▣◣  ×\n ╲█╱\n ╱ ╲"
    ]
  }

  @ascii_portraits %{
    idle: ["[b]\n/|>\n/ v", "[b]\n<|/\n/ v", "[b]\n/|>\n^ v"],
    thinking: ["[b] .\n/|>\n/ v", "[b] ..\n<|/\n/ v", "[b] ...\n/|>\n^ v"],
    running: ["[b]\n/|>_\n/ v", "[b]\n_|/\n /^", "[b]\n<|>\n/ v_"],
    waiting_confirmation: ["[b] ?\n/|>\n/ v", "[b] !\n<|/\n/ v"],
    tool_running: ["[b]\n/|>_\n/ v", "[b]\n_|/\n /^", "[b]\n<|>\n/ v_"],
    error: ["[!]\n/|>\n/ v", "[x]\n<|/\n/ v"]
  }

  @unicode_runners %{
    idle: [
      "ᕕ(◢▣◣)ᕗ ▱▱▱",
      " ᕕ(◢▣◣)ᕗ ▰▱▱",
      "  ᕕ(◢▣◣)ᕗ ▰▰▱",
      " ᕙ(◢▣◣)ᕘ ▰▰▰"
    ],
    thinking: [
      "◢▣◣ scan ·  ",
      "◢▣◣ scan ·· ",
      "◢▣◣ scan ···",
      "◢▣◣ scan ·· "
    ],
    running: [
      "▸ ᕕ(◢▣◣)ᕗ   ",
      " ▸ ᕕ(◢▣◣)ᕗ  ",
      "  ▸ ᕙ(◢▣◣)ᕘ ",
      "   ▸ ᕙ(◢▣◣)ᕘ"
    ],
    waiting_confirmation: ["◢▣◣ ? ▱", "◢▣◣ ! ▰", "◢▣◣ ? ▱", "◢▣◣ ! ▰"],
    tool_running: [
      "⚙ ᕕ(◢▣◣)ᕗ   ",
      " ⚙ ᕕ(◢▣◣)ᕗ  ",
      "  ⚙ ᕙ(◢▣◣)ᕘ ",
      "   ⚙ ᕙ(◢▣◣)ᕘ"
    ],
    error: ["◢▣◣ !", "◢▣◣ ×"]
  }

  @ascii_runners %{
    idle: ["o[b]o ...", " o[b]o #..", "  o[b]o ##.", " <[b]> ###"],
    thinking: ["[b] scan .  ", "[b] scan .. ", "[b] scan ...", "[b] scan .. "],
    running: ["> o[b]>   ", " > o[b]>  ", "  > <[b] ", "   > <[b]"],
    waiting_confirmation: ["[b]? .", "[b]! #"],
    tool_running: ["* o[b]>   ", " * o[b]>  ", "  * <[b] ", "   * <[b]"],
    error: ["[!]", "[x]"]
  }

  def frame(step, unicode? \\ true), do: frame(:idle, step, unicode?)

  def frame(status, step, unicode?) do
    status
    |> runner_frames(unicode?)
    |> at(step)
  end

  def portrait(status, step, unicode? \\ true) do
    status
    |> portrait_frames(unicode?)
    |> at(step)
  end

  def frames(status, unicode? \\ true), do: portrait_frames(status, unicode?)

  def header(status, step, unicode? \\ true) do
    label =
      case normalize(status) do
        :thinking -> "scanning"
        :tool_running -> "running"
        :running -> "running"
        :waiting_confirmation -> "waiting"
        :error -> "alert"
        _ -> "ready"
      end

    frame(status, step, unicode?) <> " " <> label
  end

  defp at(frames, step), do: Enum.at(frames, rem(max(step, 0), length(frames)))

  defp portrait_frames(status, true),
    do: Map.get(@unicode_portraits, normalize(status), @unicode_portraits.idle)

  defp portrait_frames(status, false),
    do: Map.get(@ascii_portraits, normalize(status), @ascii_portraits.idle)

  defp runner_frames(status, true),
    do: Map.get(@unicode_runners, normalize(status), @unicode_runners.idle)

  defp runner_frames(status, false),
    do: Map.get(@ascii_runners, normalize(status), @ascii_runners.idle)

  defp normalize(:thinking), do: :thinking
  defp normalize(:tool_running), do: :tool_running
  defp normalize(:waiting_for_confirmation), do: :waiting_confirmation
  defp normalize(:error), do: :error
  defp normalize(:running), do: :running
  defp normalize(_status), do: :idle
end
