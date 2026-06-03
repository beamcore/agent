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

  test "create_file creates a new file with monitoring data" do
    path = Path.join(@test_dir, "new_file.txt")

    result =
      modify!(%{
        "operation" => "create_file",
        "path" => path,
        "content" => "hello world\n"
      })

    assert result["ok"]
    assert result["changed"]
    assert result["operation"] == "create_file"
    assert result["path"] == path
    assert result["bytes_before"] == 0
    assert result["bytes_after"] == byte_size("hello world\n")
    assert is_binary(result["sha256_before"])
    assert is_binary(result["sha256_after"])
    assert result["diff"] =~ "+hello world"
    assert File.read!(path) == "hello world\n"
  end

  test "create_file overwrites only with explicit overwrite true" do
    path = Path.join(@test_dir, "existing.txt")
    File.write!(path, "original content\n")

    denied =
      modify!(%{
        "operation" => "create_file",
        "path" => path,
        "content" => "new content\n"
      })

    refute denied["ok"]
    assert denied["summary"] =~ "overwrite=true"
    assert File.read!(path) == "original content\n"

    allowed =
      modify!(%{
        "operation" => "create_file",
        "path" => path,
        "content" => "new content\n",
        "overwrite" => true
      })

    assert allowed["ok"]
    assert File.read!(path) == "new content\n"
  end

  test "replace_exact replaces a single occurrence" do
    path = Path.join(@test_dir, "replace.txt")
    File.write!(path, "line 1\nline 2\nline 3\n")

    result =
      modify!(%{
        "operation" => "replace_exact",
        "path" => path,
        "old" => "line 2",
        "new" => "updated line 2"
      })

    assert result["ok"]
    assert result["matched_occurrences"] == 1
    assert File.read!(path) == "line 1\nupdated line 2\nline 3\n"
  end

  test "replace_exact can target an explicit occurrence" do
    path = Path.join(@test_dir, "occurrence.txt")
    File.write!(path, "same\nsame\nsame\n")

    result =
      modify!(%{
        "operation" => "replace_exact",
        "path" => path,
        "old" => "same",
        "new" => "second",
        "occurrence" => 2
      })

    assert result["ok"]
    assert result["matched_occurrences"] == 3
    assert File.read!(path) == "same\nsecond\nsame\n"
  end

  test "insert_before and insert_after use exact anchors" do
    path = Path.join(@test_dir, "insert.txt")
    File.write!(path, "alpha\nomega\n")

    before =
      modify!(%{
        "operation" => "insert_before",
        "path" => path,
        "anchor" => "omega",
        "content" => "middle\n"
      })

    assert before["ok"]
    assert File.read!(path) == "alpha\nmiddle\nomega\n"

    after_insert =
      modify!(%{
        "operation" => "insert_after",
        "path" => path,
        "anchor" => "omega\n",
        "content" => "tail\n"
      })

    assert after_insert["ok"]
    assert File.read!(path) == "alpha\nmiddle\nomega\ntail\n"
  end

  test "replace_range replaces 1-based inclusive line ranges" do
    path = Path.join(@test_dir, "range.txt")
    File.write!(path, "one\ntwo\nthree\nfour\n")

    result =
      modify!(%{
        "operation" => "replace_range",
        "path" => path,
        "start_line" => 2,
        "end_line" => 3,
        "content" => "TWO\nTHREE"
      })

    assert result["ok"]
    assert result["matched_occurrences"] == 2
    assert File.read!(path) == "one\nTWO\nTHREE\nfour\n"
  end

  test "dry-run validates without writing" do
    path = Path.join(@test_dir, "dry_run.txt")
    File.write!(path, "original content\n")

    result =
      modify!(%{
        "operation" => "replace_exact",
        "path" => path,
        "old" => "original",
        "new" => "planned",
        "dry_run" => true
      })

    assert result["ok"]
    assert result["summary"] =~ "Dry-run"
    assert result["diff"] =~ "+planned content"
    assert File.read!(path) == "original content\n"
  end

  test "failed exact modifications leave file byte-for-byte unchanged" do
    path = Path.join(@test_dir, "failures.txt")
    original = "alpha\nbeta\nbeta\n"
    File.write!(path, original)

    for params <- [
          %{"operation" => "replace_exact", "old" => "missing", "new" => "x"},
          %{"operation" => "replace_exact", "old" => "beta", "new" => "x"},
          %{"operation" => "replace_exact", "old" => "beta", "new" => "x", "occurrence" => 3},
          %{"operation" => "replace_exact", "old" => "", "new" => "x"}
        ] do
      result = modify!(Map.put(params, "path", path))
      refute result["ok"]
      assert File.read!(path) == original
    end
  end

  test "missing and ambiguous anchors do not write" do
    path = Path.join(@test_dir, "anchors.txt")
    original = "one\ntwo\ntwo\n"
    File.write!(path, original)

    missing =
      modify!(%{
        "operation" => "insert_before",
        "path" => path,
        "anchor" => "missing",
        "content" => "x\n"
      })

    refute missing["ok"]
    assert File.read!(path) == original

    ambiguous =
      modify!(%{
        "operation" => "insert_after",
        "path" => path,
        "anchor" => "two",
        "content" => "x\n"
      })

    refute ambiguous["ok"]
    assert ambiguous["summary"] =~ "ambiguous"
    assert File.read!(path) == original
  end

  test "invalid range, checksum mismatch, and no-op edits do not write" do
    path = Path.join(@test_dir, "guards.txt")
    original = "one\ntwo\n"
    File.write!(path, original)

    invalid_range =
      modify!(%{
        "operation" => "replace_range",
        "path" => path,
        "start_line" => 3,
        "end_line" => 4,
        "content" => "bad"
      })

    refute invalid_range["ok"]

    checksum_mismatch =
      modify!(%{
        "operation" => "replace_exact",
        "path" => path,
        "old" => "one",
        "new" => "ONE",
        "expected_sha256" => String.duplicate("0", 64)
      })

    refute checksum_mismatch["ok"]
    assert checksum_mismatch["summary"] =~ "checksum mismatch"

    no_op =
      modify!(%{
        "operation" => "replace_exact",
        "path" => path,
        "old" => "one",
        "new" => "one"
      })

    refute no_op["ok"]
    assert no_op["summary"] =~ "would not change"
    assert File.read!(path) == original
  end

  test "path escape, directories, and binary targets are rejected" do
    assert modify!(%{"operation" => "create_file", "path" => "../outside.txt", "content" => "x"})[
             "summary"
           ] =~ "path traversal"

    dir = Path.join(@test_dir, "dir")
    File.mkdir_p!(dir)

    directory = modify!(%{"operation" => "create_file", "path" => dir, "content" => "x"})
    refute directory["ok"]
    assert directory["summary"] =~ "directory"

    binary_path = Path.join(@test_dir, "binary.bin")
    File.write!(binary_path, <<0, 1, 2, 3>>)

    binary =
      modify!(%{
        "operation" => "replace_exact",
        "path" => binary_path,
        "old" => <<1>>,
        "new" => "x"
      })

    refute binary["ok"]
    assert binary["summary"] =~ "binary"
  end

  defp modify!(params), do: params |> Modify.execute() |> Jason.decode!()
end
