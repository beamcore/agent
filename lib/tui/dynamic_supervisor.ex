defmodule Beamcore.TUI.DynamicSupervisor do
  @moduledoc """
  A DynamicSupervisor that manages the lifecycle of the TUI process on demand.
  This allows starting the interactive TUI under the main application's supervision
  tree dynamically when requested by chat/2.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
