defmodule Beamcore.TUI.GlyphsTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Glyphs

  test "diamond falls back to an ASCII star on non-unicode terminals" do
    assert Glyphs.diamond(true) == "◆"
    assert Glyphs.diamond(false) == "*"
  end

  test "border_type squares off when unicode is unavailable" do
    assert Glyphs.border_type(true) == :rounded
    assert Glyphs.border_type(false) == :plain
  end

  test "placeholder falls back to an ASCII ellipsis" do
    assert Glyphs.placeholder(true) == "···"
    assert Glyphs.placeholder(false) == "..."
  end

  test "status markers have ASCII fallbacks for every run status" do
    assert Glyphs.status(:done, true) == "✓"
    assert Glyphs.status(:done, false) == "v"
    assert Glyphs.status(:completed, false) == "v"

    assert Glyphs.status(:error, true) == "✗"
    assert Glyphs.status(:error, false) == "x"
    assert Glyphs.status(:blocked, false) == "x"

    assert Glyphs.status(:running, true) == "◐"
    assert Glyphs.status(:running, false) == "*"

    assert Glyphs.status(:queued, true) == "·"
    assert Glyphs.status(:queued, false) == "."
    assert Glyphs.status(:anything_else, false) == "."
  end
end
