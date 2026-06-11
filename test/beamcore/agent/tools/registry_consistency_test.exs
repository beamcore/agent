defmodule Beamcore.Agent.Tools.RegistryConsistencyTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.ToolRuntime
  alias Beamcore.Agent.Tools.Dispatcher

  test "every autonomous mode resolves to the same single model-facing tool" do
    for caps <- [ToolRuntime.default(), ToolRuntime.yolo(), ToolRuntime.chat()] do
      assert ToolRuntime.allowed_tool_names(caps) == ["eeva"]
      assert Enum.map(Dispatcher.tool_specs(caps), & &1.function.name) == ["eeva"]
    end
  end
end
