defmodule Beamcore.Agent.Tools.ModifyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Modify

  @test_dir "test/tmp_modify_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Full File Write & Path Safety Tests
  # ---------------------------------------------------------------------------

  test "modify_file creates a new file with content" do
    path = Path.join(@test_dir, "new_file.txt")
    result = Modify.execute(%{"path" => path, "content" => "hello world"})

    assert result =~ "Successfully wrote to"
    assert File.read!(path) == "hello world"
  end

  test "modify_file overwrites an existing file" do
    path = Path.join(@test_dir, "existing.txt")
    File.write!(path, "original content")

    result = Modify.execute(%{"path" => path, "content" => "new content"})

    assert result =~ "Successfully wrote to"
    assert File.read!(path) == "new content"
  end

  test "modify_file rejects absolute paths" do
    result = Modify.execute(%{"path" => "/tmp/agent_outside.txt", "content" => "nope"})
    assert result =~ "absolute paths are not allowed"
  end

  test "modify_file rejects path traversal" do
    result = Modify.execute(%{"path" => "../agent_outside.txt", "content" => "nope"})
    assert result =~ "path traversal is not allowed"
  end

  test "modify_file de-obfuscates email protection placeholders" do
    path = Path.join(@test_dir, "emails.txt")
    result = Modify.execute(%{"path" => path, "content" => "debug \"[email protected]\" --all\n"})

    assert result =~ "Successfully wrote to"
    assert File.read!(path) == "debug \"$@\" --all\n"
  end

  # ---------------------------------------------------------------------------
  # Targeted Single Edit Tests
  # ---------------------------------------------------------------------------

  test "modify_file performs exact single edit" do
    path = Path.join(@test_dir, "edit.txt")
    File.write!(path, "line 1\nline 2\nline 3\n")

    result =
      Modify.execute(%{
        "path" => path,
        "edits" => [
          %{"search" => "line 2", "replace" => "updated line 2"}
        ]
      })

    assert result =~ "Successfully updated"
    assert File.read!(path) == "line 1\nupdated line 2\nline 3\n"
  end

  # ---------------------------------------------------------------------------
  # Robust Matching Tiers
  # ---------------------------------------------------------------------------

  test "modify_file matches formatting-insensitively (Tier 2)" do
    path = Path.join(@test_dir, "formatting.txt")
    # File has extra spacing and double quotes
    File.write!(path, "    def my_fun( a,   b ):\n        return \"success\"\n")

    # Search query has different spacing and single quotes
    result =
      Modify.execute(%{
        "path" => path,
        "edits" => [
          %{
            "search" => "def my_fun(a, b):\n    return 'success'",
            "replace" => "def my_fun(a, b):\n    return 'updated'"
          }
        ]
      })

    assert result =~ "Successfully updated"
    # Indentation was aligned (+4 spaces relative to search query block)
    # File is updated, retaining original lineending style
    assert File.read!(path) == "    def my_fun(a, b):\n        return 'updated'\n"
  end

  test "modify_file matches comment-insensitively (Tier 3)" do
    path = Path.join(@test_dir, "comments.txt")
    File.write!(path, "def execute(args) do # some code comment\n  IO.puts(\"ok\")\nend")

    # Search block has no comments
    result =
      Modify.execute(%{
        "path" => path,
        "edits" => [
          %{
            "search" => "def execute(args) do\n  IO.puts('ok')",
            "replace" => "def execute(args) do\n  IO.puts('changed')"
          }
        ]
      })

    assert result =~ "Successfully updated"
    assert File.read!(path) == "def execute(args) do\n  IO.puts('changed')\nend"
  end

  test "modify_file preserves relative indentation" do
    path = Path.join(@test_dir, "indent.txt")
    File.write!(path, "class Calc:\n    def run(self):\n        x = 10\n        return x")

    # Agent provides 0 indentation on replacement block
    result =
      Modify.execute(%{
        "path" => path,
        "edits" => [
          %{
            "search" => "x = 10\nreturn x",
            "replace" => "y = 20\nreturn y"
          }
        ]
      })

    assert result =~ "Successfully updated"
    # The replacement is aligned with the file's original 8-space indentation!
    assert File.read!(path) == "class Calc:\n    def run(self):\n        y = 20\n        return y"
  end

  # ---------------------------------------------------------------------------
  # Atomic Multiple Edits
  # ---------------------------------------------------------------------------

  test "modify_file applies multiple non-overlapping edits atomically in reverse order" do
    path = Path.join(@test_dir, "multi.txt")
    File.write!(path, "first block\n\nsecond block\n\nthird block\n")

    result =
      Modify.execute(%{
        "path" => path,
        "edits" => [
          %{"search" => "third block", "replace" => "third updated"},
          %{"search" => "first block", "replace" => "first updated"}
        ]
      })

    assert result =~ "Successfully updated"
    assert File.read!(path) == "first updated\n\nsecond block\n\nthird updated\n"
  end

  test "modify_file rejects overlapping multi-edits" do
    path = Path.join(@test_dir, "overlap.txt")
    File.write!(path, "one\ntwo\nthree\n")

    result =
      Modify.execute(%{
        "path" => path,
        "edits" => [
          %{"search" => "one\ntwo", "replace" => "1-2"},
          %{"search" => "two\nthree", "replace" => "2-3"}
        ]
      })

    assert result =~ "overlap"
    # Content remains unchanged due to atomicity
    assert File.read!(path) == "one\ntwo\nthree\n"
  end

  test "modify_file handles empty and invalid inputs gracefully" do
    path = Path.join(@test_dir, "error.txt")
    File.write!(path, "content")

    # Missing both edits and content
    assert Modify.execute(%{"path" => path}) =~ "Either 'content' or 'edits' must be provided"

    # Providing both edits and content
    assert Modify.execute(%{
             "path" => path,
             "content" => "full",
             "edits" => [%{"search" => "c", "replace" => "d"}]
           }) =~ "Provide either 'content'"
  end

  test "modify_file supports dry-run without writing changes" do
    path = Path.join(@test_dir, "dry_run.txt")
    original = "original content"
    File.write!(path, original)

    result =
      Modify.execute(%{
        "path" => path,
        "dry_run" => true,
        "edits" => [%{"search" => "original content", "replace" => "new content"}]
      })

    assert result =~ "Dry-run succeeded"
    assert result =~ "new content"
    # Actual file on disk must be unmodified!
    assert File.read!(path) == original
  end
end
