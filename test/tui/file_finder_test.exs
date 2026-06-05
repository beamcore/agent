defmodule Beamcore.TUI.FileFinderTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.FileFinder

  describe "parse/2" do
    test "returns :no_file_query when @ is absent" do
      assert FileFinder.parse("hello world", {0, 5}) == :no_file_query
    end

    test "triggers on @ followed by characters at end of line" do
      assert FileFinder.parse("@lib/tui", {0, 8}) == {:file_query, "lib/tui", 0, 8}
      assert FileFinder.parse("Please look at @lib", {0, 19}) == {:file_query, "lib", 15, 19}
    end

    test "triggers on @[ followed by characters" do
      assert FileFinder.parse("@[lib", {0, 5}) == {:file_query, "[lib", 0, 5}
      assert FileFinder.parse("Check @[lib/tui", {0, 15}) == {:file_query, "[lib/tui", 6, 15}
    end

    test "returns :no_file_query if cursor is not directly at/in the token" do
      # Cursor is at the space after @lib
      assert FileFinder.parse("@lib ", {0, 5}) == :no_file_query
      # Cursor is at another word
      assert FileFinder.parse("@lib hello", {0, 10}) == :no_file_query
    end

    test "returns :no_file_query if token is a completed tag (ends with ])" do
      assert FileFinder.parse("@[lib/tui/file_finder.ex]", {0, 25}) == :no_file_query
      assert FileFinder.parse("@[lib/tui/file_finder.ex] ", {0, 26}) == :no_file_query
    end
  end

  describe "search/2" do
    test "correctly trims leading [ from the query" do
      cache = ["lib/tui/file_finder.ex", "lib/tui/events.ex", "test/tui/history_test.exs"]

      results = FileFinder.search("[lib", cache)
      assert "lib/tui/file_finder.ex" in results
      assert "lib/tui/events.ex" in results
      refute "test/tui/history_test.exs" in results
    end
  end
end
