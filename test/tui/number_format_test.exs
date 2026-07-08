defmodule Beamcore.TUI.NumberFormatTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.NumberFormat

  test "formats compact token counts without external dependencies" do
    assert NumberFormat.compact(nil) == "0"
    assert NumberFormat.compact(0) == "0"
    assert NumberFormat.compact(1) == "1"
    assert NumberFormat.compact(500) == "500"
    assert NumberFormat.compact(999) == "999"

    # 1k – 10k: one decimal
    assert NumberFormat.compact(1_000) == "1k"
    assert NumberFormat.compact(1_500) == "1.5k"
    assert NumberFormat.compact(2_300) == "2.3k"
    assert NumberFormat.compact(9_999) == "10k"

    # 10k – 1M: rounded k
    assert NumberFormat.compact(10_000) == "10k"
    assert NumberFormat.compact(45_000) == "45k"
    assert NumberFormat.compact(999_999) == "999k"

    # 1M – 10M: one decimal M
    assert NumberFormat.compact(1_000_000) == "1M"
    assert NumberFormat.compact(1_234_567) == "1.2M"

    # ≥ 10M: rounded M
    assert NumberFormat.compact(10_000_000) == "10M"
    assert NumberFormat.compact(12_000_000) == "12M"

    # Negative
    assert NumberFormat.compact(-1_500) == "-1.5k"
  end
end
