defmodule Beamcore.TUI.NumberFormatTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.NumberFormat

  test "formats compact token counts without external dependencies" do
    assert NumberFormat.compact(nil) == "0"
    assert NumberFormat.compact(0) == "0"
    assert NumberFormat.compact(999) == "999"
    assert NumberFormat.compact(1_000) == "1K"
    assert NumberFormat.compact(1_500) == "1.5K"
    assert NumberFormat.compact(1_234_567) == "1.2M"
    assert NumberFormat.compact(-1_500) == "-1.5K"
  end
end
