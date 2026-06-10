defmodule Beamcore.Agent.Chat.SearchConductorTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.{SearchConductor, ToolPolicy}
  alias Beamcore.Agent.Tools.Dispatcher

  test "conductor receives only the eeva tool specification" do
    policy = ToolPolicy.default()
    assert Dispatcher.conductor_tool_specs(policy) |> Enum.map(& &1.function.name) == ["eeva"]
  end

  test "helper policy remains eeva-only and network-disabled" do
    policy = ToolPolicy.local_context_helper(ToolPolicy.default())
    assert ToolPolicy.allowed_tool_names(policy) == ["eeva"]
    refute policy.allow_network
  end

  test "search conductor module remains available" do
    assert function_exported?(SearchConductor, :preflight, 5)
  end
end
