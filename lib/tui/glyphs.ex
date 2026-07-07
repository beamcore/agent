defmodule Beamcore.TUI.Glyphs do
  @moduledoc """
  Capability-aware glyphs for the shell's framed surfaces.

  Every decorative glyph the restyle draws — the accent title marker, rounded
  block corners, the coming-soon placeholder, and the activity status cells —
  has an ASCII fallback chosen by the terminal's `unicode?` capability, the same
  flag that already gates the mascot, the input spinner, and the splash. Without
  it a non-unicode terminal renders the mascot in ASCII while the surrounding
  chrome shows boxes.
  """

  @doc "Accent marker prefixed to every framed surface's title."
  @spec diamond(boolean()) :: String.t()
  def diamond(true), do: "◆"
  def diamond(false), do: "*"

  @doc "Block corner style: rounded when unicode, square otherwise."
  @spec border_type(boolean()) :: :rounded | :plain
  def border_type(true), do: :rounded
  def border_type(false), do: :plain

  @doc "Placeholder name shown for an inactive coming-soon tab."
  @spec placeholder(boolean()) :: String.t()
  def placeholder(true), do: "···"
  def placeholder(false), do: "..."

  @doc "Activity status marker for a run status (see `status_display/2`)."
  @spec status(atom(), boolean()) :: String.t()
  def status(status, unicode?) when status in [:done, :completed], do: done(unicode?)
  def status(status, unicode?) when status in [:error, :blocked], do: failed(unicode?)
  def status(:running, unicode?), do: running(unicode?)
  def status(_status, unicode?), do: pending(unicode?)

  defp done(true), do: "✓"
  defp done(false), do: "v"

  defp failed(true), do: "✗"
  defp failed(false), do: "x"

  defp running(true), do: "◐"
  defp running(false), do: "*"

  defp pending(true), do: "·"
  defp pending(false), do: "."
end
