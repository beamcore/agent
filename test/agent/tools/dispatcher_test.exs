defmodule Beamcore.Agent.Tools.DispatcherTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Tools.Dispatcher

  test "execute returns error for unknown tool" do
    result = Dispatcher.execute("unknown_tool", %{})
    assert result == "Function not implemented"
  end

  test "tool_specs returns direct tool specifications without task by default" do
    specs = Dispatcher.tool_specs()
    names = Enum.map(specs, fn spec -> spec.function.name end)

    assert "read" in names
    assert "mix" in names
    refute "task" in names
  end

  test "tool_specs includes task only when policy allows explicit delegation" do
    policy = ToolPolicy.from_user_message("Use task delegation for this large audit.")
    names = Dispatcher.tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    assert "task" in names
  end

  test "conductor_tool_specs applies read-only policy" do
    policy = ToolPolicy.from_user_message("Read-only smoke test. Do not modify files.")
    names = Dispatcher.conductor_tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    assert Enum.sort(names) == Enum.sort(~w(read grep glob tree git mix))
  end

  test "execute blocks mutating tools in read-only mode" do
    policy = ToolPolicy.from_user_message("Do not modify files.")

    result = Dispatcher.execute("write", %{"filePath" => "tmp.txt", "content" => "bad"}, policy)

    assert result =~ "read-only policy"
  end
end
