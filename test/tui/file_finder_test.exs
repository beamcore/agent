defmodule Beamcore.TUI.FileFinderTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.FileFinder
  alias Beamcore.Agent.Tools.PathSafety

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

  describe "load_files/0" do
    test "does not return symlinks that resolve outside the workspace" do
      root =
        Path.join(
          System.tmp_dir!(),
          "beamcore_file_finder_#{System.unique_integer([:positive])}"
        )

      outside =
        Path.join(
          System.tmp_dir!(),
          "beamcore_file_finder_outside_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(outside)
      File.write!(Path.join(root, "lib/inside.ex"), "defmodule Inside, do: :ok\n")
      File.write!(Path.join(outside, "secret.ex"), "secret\n")
      File.ln_s!(Path.join(outside, "secret.ex"), Path.join(root, "lib/outside_link.ex"))

      previous = PathSafety.configure_workspace_root(root)

      try do
        files = FileFinder.load_files()

        assert "lib/inside.ex" in files
        refute "lib/outside_link.ex" in files
      after
        PathSafety.restore_workspace_root(previous)
        File.rm_rf(root)
        File.rm_rf(outside)
      end
    end
  end
end
