defmodule Beamcore.TUI.Capability do
  @moduledoc false

  def unicode?(opts \\ []) do
    Keyword.get(opts, :unicode?, true)
  end
end
