defmodule Beamcore.Agent.TUI do
  @moduledoc """
  Primary terminal UI for the agent chat.
  """

  def start(opts \\ []) do
    Beamcore.Agent.TUI.App.run(opts)
  end
end
