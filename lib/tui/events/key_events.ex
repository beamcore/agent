defmodule Beamcore.TUI.Events.KeyEvents do
  @moduledoc false

  @release_kinds ["release", :release]

  def actionable?(%ExRatatui.Event.Key{kind: kind}), do: kind not in @release_kinds
  def actionable?(%{kind: kind}), do: kind not in @release_kinds
  def actionable?(_event), do: true
end
