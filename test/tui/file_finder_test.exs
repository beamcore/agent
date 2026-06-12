defmodule Beamcore.TUI.FileFinderTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Tools.PathInput
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
      # Cursor is at the space after @lib.
      assert FileFinder.parse("@lib ", {0, 5}) == :no_file_query

      # Cursor is at another word.
      assert FileFinder.parse("@lib hello", {0, 10}) == :no_file_query
    end

    test "returns :no_file_query if token is a completed tag ending with ]" do
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
    test "includes symlinked files in the compact project file finder" do
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

      inside_file = Path.join(root, "lib/inside.ex")
      inside_link = Path.join(root, "lib/inside_link.ex")
      outside_file = Path.join(outside, "secret.ex")
      outside_link = Path.join(root, "lib/outside_link.ex")

      File.write!(inside_file, "defmodule Inside, do: :ok\n")
      File.write!(outside_file, "secret\n")

      File.ln_s!(inside_file, inside_link)
      File.ln_s!(outside_file, outside_link)

      previous = PathInput.configure_workspace_root(root)

      try do
        files = FileFinder.load_files()

        assert "lib/inside.ex" in files
        assert "lib/inside_link.ex" in files
        assert "lib/outside_link.ex" in files
      after
        PathInput.restore_workspace_root(previous)
        File.rm_rf(root)
        File.rm_rf(outside)
      end
    end
  end
end
