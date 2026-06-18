defmodule Beamcore.Agent.Chat.LoopTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Dispatcher

  test "tool specs expose only eeva" do
    specs = Dispatcher.tool_specs()
    assert Enum.map(specs, & &1.function.name) == ["eeva"]
  end
end
