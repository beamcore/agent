defmodule Beamcore.Agent.Tools.DispatcherTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Tools.Dispatcher

  test "registers only eeva" do
    assert Dispatcher.registered_tool_names() == ["eeva"]
  end

  test "provider tool specs contain only eeva" do
    specs = Dispatcher.tool_specs(ToolPolicy.default())
    assert Enum.map(specs, & &1.function.name) == ["eeva"]
  end

  test "chat mode exposes eeva for safe memory-only work" do
    assert Enum.map(Dispatcher.tool_specs(ToolPolicy.chat()), & &1.function.name) == ["eeva"]
  end

  test "unknown tool calls are rejected" do
    assert Dispatcher.execute("modify_file", %{}, ToolPolicy.default()) ==
             "Function not implemented"
  end

  test "eeva executes through the dispatcher" do
    result = Dispatcher.execute("eeva", %{"code" => "Enum.sum(1..10)"}) |> Jason.decode!()
    assert result["ok"]
    assert result["result"] == "55"
  end
end
