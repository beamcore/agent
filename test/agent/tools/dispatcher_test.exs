defmodule Beamcore.Agent.Tools.DispatcherTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Dispatcher

  test "execute returns error for unknown tool" do
    result = Dispatcher.execute("unknown_tool", %{})
    assert result == "Function not implemented"
  end

  test "tool_specs returns a list of specifications" do
    specs = Dispatcher.tool_specs()
    assert is_list(specs)
    assert length(specs) > 0

    # Check that a known tool like read is in the specs
    assert Enum.any?(specs, fn spec ->
             spec.function.name == "read"
           end)
  end

  test "conductor_tool_specs returns only the expected conductor tools" do
    specs = Dispatcher.conductor_tool_specs()
    assert is_list(specs)
    assert length(specs) == 4

    names = Enum.map(specs, fn spec -> spec.function.name end) |> Enum.sort()
    assert names == ["git", "read", "task", "tree"]
  end
end
