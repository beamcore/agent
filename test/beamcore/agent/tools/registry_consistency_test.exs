defmodule Beamcore.Agent.Tools.RegistryConsistencyTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Tools.Dispatcher

  test "every autonomous mode resolves to the same single model-facing tool" do
    for policy <- [ToolPolicy.default(), ToolPolicy.research(), ToolPolicy.local_context_helper()] do
      assert ToolPolicy.allowed_tool_names(policy) == ["eeva"]
      assert Enum.map(Dispatcher.tool_specs(policy), & &1.function.name) == ["eeva"]
    end
  end
end
