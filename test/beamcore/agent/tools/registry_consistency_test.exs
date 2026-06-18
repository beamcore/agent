defmodule Beamcore.Agent.Tools.RegistryConsistencyTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Tools.Dispatcher

  test "tool specs resolve to the single model-facing tool" do
    specs = Dispatcher.tool_specs()
    assert Enum.map(specs, & &1.function.name) == ["eeva"]
  end
end
