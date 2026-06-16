defmodule Beamcore.Agent.Tools.Eeva.Supervisor do
  @moduledoc """
  Dynamic OTP supervisor for isolated Eeva executions.

  Every model-authored program gets a temporary worker. The supervisor limits
  concurrent executions so one model turn cannot exhaust the VM by starting an
  unbounded number of evaluators.
  """

  use DynamicSupervisor

  @default_max_children 8

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    max_children = Beamcore.Config.get_setting(:eeva_max_concurrency, @default_max_children)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: max_children
    )
  end

  def start_execution(opts) when is_list(opts) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :eeva_supervisor_not_started}

      _pid ->
        DynamicSupervisor.start_child(__MODULE__, {Beamcore.Agent.Tools.Eeva.Worker, opts})
    end
  end
end
