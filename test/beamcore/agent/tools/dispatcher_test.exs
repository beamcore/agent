defmodule Beamcore.Agent.Tools.DispatcherTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Tools.Dispatcher

  setup do
    previous_timeout = Beamcore.Config.get(:eeva_timeout_ms)
    Beamcore.Config.put(:eeva_timeout_ms, "10000")

    on_exit(fn ->
      case previous_timeout do
        nil -> Beamcore.Config.delete(:eeva_timeout_ms)
        value -> Beamcore.Config.put(:eeva_timeout_ms, value)
      end
    end)
  end

  test "provider tool specs contain only eeva" do
    specs = Dispatcher.tool_specs()
    assert Enum.map(specs, & &1.function.name) == ["eeva"]
  end

  test "unknown tool calls are rejected" do
    assert Dispatcher.execute("modify_file", %{}) ==
             "Function not implemented"
  end

  test "eeva executes through the dispatcher" do
    result = Dispatcher.execute("eeva", %{"code" => "Enum.sum(1..10)"}) |> Jason.decode!()
    assert result["ok"]
    assert result["result"] == "55"
  end
end
