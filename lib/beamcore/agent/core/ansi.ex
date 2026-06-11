defmodule Beamcore.Agent.Core.ANSI do
  @moduledoc """
  ANSI escape sequence constants for terminal manipulation.
  """

  @save_cursor "\e7"

  @restore_cursor "\e8"

  @clear_line "\e[K"

  @clear_screen "\e[2J"

  @doc "Move cursor to row `n`, column 1."
  def move_to_row(n), do: "\e[#{n};1H"

  @doc "Move cursor to absolute bottom line."
  def move_to_bottom, do: "\e[999;1H"

  @doc "Set scrolling region from row `start` to row `finish`."
  def set_scroll_region(start, finish), do: "\e[#{start};#{finish}r"

  @reset_scroll "\e[r"

  @reset "\e[0m"

  @bold "\e[1m"

  @bright_white "\e[97m"

  @bg_black "\e[40m"

  @bg_default "\e[49m"

  @fg_default "\e[39m"

  @doc "Returns the ANSI sequence to save cursor position."
  def save_cursor, do: @save_cursor

  @doc "Returns the ANSI sequence to restore cursor position."
  def restore_cursor, do: @restore_cursor

  @doc "Returns the ANSI sequence to clear the current line."
  def clear_line, do: @clear_line

  @doc "Returns the ANSI sequence to clear the entire screen."
  def clear_screen, do: @clear_screen

  @doc "Returns the ANSI sequence to reset scrolling region."
  def reset_scroll, do: @reset_scroll

  @doc "Returns the ANSI sequence to reset all terminal attributes."
  def reset, do: @reset

  @doc "Returns the ANSI sequence for bold text."
  def bold, do: @bold

  @doc "Returns the ANSI sequence for bright white text."
  def bright_white, do: @bright_white

  @doc "Returns the ANSI sequence for black background."
  def bg_black, do: @bg_black

  @doc "Returns the ANSI sequence for default background."
  def bg_default, do: @bg_default

  @doc "Returns the ANSI sequence for default text color."
  def fg_default, do: @fg_default

  @doc "Returns a combined ANSI sequence for status bar styling."
  def status_bar_style, do: bg_black() <> bright_white() <> bold()

  @doc "Returns the ANSI sequence to reset all styling."
  def reset_style, do: reset() <> fg_default() <> bg_default()
end
