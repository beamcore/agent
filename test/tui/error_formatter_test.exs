defmodule Beamcore.TUI.ErrorFormatterTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.ErrorFormatter

  test "compacts escaped multiline provider errors" do
    input = Enum.map_join(1..30, "\\n", &"line #{&1}")
    output = ErrorFormatter.format(input)

    assert output =~ "line 1"
    assert output =~ "more lines hidden"
    refute String.length(output) > 1_200
  end

  test "formats structured errors without dumping unlimited nested data" do
    output =
      ErrorFormatter.format(%{
        message: "provider unavailable",
        details: List.duplicate(%{x: 1}, 100)
      })

    assert output == "provider unavailable"
  end
end
