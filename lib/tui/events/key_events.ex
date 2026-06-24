defmodule Beamcore.TUI.Events.KeyEvents do
  @moduledoc false

  @ignored_kinds ["release", :release, "repeat", :repeat]

  def actionable?(%ExRatatui.Event.Key{kind: kind}), do: kind not in @ignored_kinds
  def actionable?(%{kind: kind}), do: kind not in @ignored_kinds
  def actionable?(_event), do: true
end
