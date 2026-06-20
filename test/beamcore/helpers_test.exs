defmodule Beamcore.HelpersTest do
  use ExUnit.Case, async: true

  test "lists Beamcore.Memory public functions" do
    functions = Beamcore.Helpers.info(Beamcore.Memory, :functions)
    assert {:remember, 3} in functions
    assert {:recall, 3} in functions
  end

  test "only Beamcore modules may be inspected" do
    assert_raise ArgumentError, fn -> Beamcore.Helpers.info(String, :functions) end
  end

  test "lists loaded Beamcore modules without creating atoms" do
    assert Beamcore.Memory in Beamcore.Helpers.modules("Beamcore")
  end
end
