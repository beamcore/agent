defmodule Beamcore.Agent.Core.ANSITest do
  use ExUnit.Case

  alias Beamcore.Agent.Core.ANSI

  test "save_cursor/0 returns the correct ANSI sequence" do
    assert ANSI.save_cursor() == "\e7"
  end

  test "restore_cursor/0 returns the correct ANSI sequence" do
    assert ANSI.restore_cursor() == "\e8"
  end

  test "clear_line/0 returns the correct ANSI sequence" do
    assert ANSI.clear_line() == "\e[K"
  end

  test "clear_screen/0 returns the correct ANSI sequence" do
    assert ANSI.clear_screen() == "\e[2J"
  end

  test "move_to_row/1 returns the correct ANSI sequence" do
    assert ANSI.move_to_row(5) == "\e[5;1H"
    assert ANSI.move_to_row(24) == "\e[24;1H"
  end

  test "move_to_bottom/0 returns the correct ANSI sequence" do
    assert ANSI.move_to_bottom() == "\e[999;1H"
  end

  test "set_scroll_region/2 returns the correct ANSI sequence" do
    assert ANSI.set_scroll_region(1, 23) == "\e[1;23r"
    assert ANSI.set_scroll_region(5, 10) == "\e[5;10r"
  end

  test "reset_scroll/0 returns the correct ANSI sequence" do
    assert ANSI.reset_scroll() == "\e[r"
  end

  test "reset/0 returns the correct ANSI sequence" do
    assert ANSI.reset() == "\e[0m"
  end

  test "bold/0 returns the correct ANSI sequence" do
    assert ANSI.bold() == "\e[1m"
  end

  test "bright_white/0 returns the correct ANSI sequence" do
    assert ANSI.bright_white() == "\e[97m"
  end

  test "bg_black/0 returns the correct ANSI sequence" do
    assert ANSI.bg_black() == "\e[40m"
  end

  test "bg_default/0 returns the correct ANSI sequence" do
    assert ANSI.bg_default() == "\e[49m"
  end

  test "fg_default/0 returns the correct ANSI sequence" do
    assert ANSI.fg_default() == "\e[39m"
  end

  test "status_bar_style/0 returns combined styling" do
    style = ANSI.status_bar_style()
    assert String.contains?(style, ANSI.bg_black())
    assert String.contains?(style, ANSI.bright_white())
    assert String.contains?(style, ANSI.bold())
  end

  test "reset_style/0 returns combined reset sequences" do
    style = ANSI.reset_style()
    assert String.contains?(style, ANSI.reset())
    assert String.contains?(style, ANSI.fg_default())
    assert String.contains?(style, ANSI.bg_default())
  end
end
