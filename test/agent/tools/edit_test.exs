defmodule Beamcore.Agent.Tools.EditTest do
  use ExUnit.Case

  @test_dir "test/tmp_edit_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  test "replaces old string with new string" do
    file_path = Path.join(@test_dir, "replace.txt")
    File.write!(file_path, "Hello world!")

    params = %{
      "path" => file_path,
      "old_string" => "world",
      "new_string" => "Elixir"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated #{Path.expand(file_path)}")
    assert output =~ "-Hello world!"
    assert output =~ "+Hello Elixir!"
    assert File.read!(file_path) == "Hello Elixir!"
  end

  test "fails when old_string is ambiguous" do
    file_path = Path.join(@test_dir, "ambiguous.txt")
    File.write!(file_path, "apple banana apple")

    params = %{
      "path" => file_path,
      "old_string" => "apple",
      "new_string" => "orange"
    }

    assert String.starts_with?(
             Beamcore.Agent.Tools.Edit.execute(params),
             "Error: old_string is ambiguous"
           )
  end

  test "fails when old_string is not found" do
    file_path = Path.join(@test_dir, "not_found.txt")
    File.write!(file_path, "apple banana orange")

    params = %{
      "path" => file_path,
      "old_string" => "grape",
      "new_string" => "pear"
    }

    assert String.starts_with?(
             Beamcore.Agent.Tools.Edit.execute(params),
             "Error: old_string not found in file."
           )
  end

  test "fails when file does not exist" do
    params = %{
      "path" => "test/tmp_edit_test/nonexistent.txt",
      "old_string" => "foo",
      "new_string" => "bar"
    }

    assert String.starts_with?(Beamcore.Agent.Tools.Edit.execute(params), "Error reading file")
  end

  test "rejects absolute paths" do
    params = %{
      "path" => "/tmp/agent_edit_outside.txt",
      "old_string" => "foo",
      "new_string" => "bar"
    }

    assert Beamcore.Agent.Tools.Edit.execute(params) =~ "absolute paths are not allowed"
  end

  test "rejects path traversal" do
    params = %{
      "path" => "../agent_edit_outside.txt",
      "old_string" => "foo",
      "new_string" => "bar"
    }

    assert Beamcore.Agent.Tools.Edit.execute(params) =~ "path traversal is not allowed"
  end

  test "succeeds uniquely with line range constraints even if ambiguous globally" do
    file_path = Path.join(@test_dir, "range.txt")
    File.write!(file_path, "apple\nbanana\napple\ncherry")

    params = %{
      "path" => file_path,
      "old_string" => "apple",
      "new_string" => "orange",
      "start_line" => 1,
      "end_line" => 2
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated #{Path.expand(file_path)}")
    assert File.read!(file_path) == "orange\nbanana\napple\ncherry"
  end

  test "succeeds using tolerance window when line numbers are slightly off" do
    file_path = Path.join(@test_dir, "shifted.txt")
    File.write!(file_path, "1\n2\n3\n4\n5\nfind_me\n7\n8\n9")

    params = %{
      "path" => file_path,
      "old_string" => "find_me",
      "new_string" => "found_me",
      "start_line" => 2,
      "end_line" => 3
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated #{Path.expand(file_path)}")
    assert File.read!(file_path) == "1\n2\n3\n4\n5\nfound_me\n7\n8\n9"
  end

  test "performs dry run validation without writing changes" do
    file_path = Path.join(@test_dir, "dry_run.txt")
    File.write!(file_path, "Hello world!")

    params = %{
      "path" => file_path,
      "old_string" => "world",
      "new_string" => "Elixir",
      "dry_run" => true
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)

    assert String.starts_with?(
             output,
             "Dry-run succeeded: #{Path.expand(file_path)} would be updated."
           )

    assert output =~ "-Hello world!"
    assert output =~ "+Hello Elixir!"
    assert File.read!(file_path) == "Hello world!"
  end

  test "reports precise line numbers in ambiguity errors" do
    file_path = Path.join(@test_dir, "ambig_lines.txt")
    File.write!(file_path, "apple\nbanana\napple\ncherry\napple")

    params = %{
      "path" => file_path,
      "old_string" => "apple",
      "new_string" => "orange"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert output =~ "Error: old_string is ambiguous."
    assert output =~ "occurs 3 times"
    assert output =~ "at lines: 1, 3, 5"
  end

  test "reports helpful did-you-mean suggestion when match is not found" do
    file_path = Path.join(@test_dir, "fuzzy.txt")
    File.write!(file_path, "line1\nline2\n  def my_speclal_function do\nline4")

    params = %{
      "path" => file_path,
      "old_string" => "def my_special_function do",
      "new_string" => "def foo do"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert output =~ "Error: old_string not found in file."
    assert output =~ "Did you mean the block at lines 3-3"
    assert output =~ "similarity:"
    assert output =~ "=> 3:   def my_speclal_function do"
  end

  # ---- Parity Tests ----

  test "preserves UTF-8 BOM" do
    file_path = Path.join(@test_dir, "bom.txt")
    File.write!(file_path, "\uFEFFHello world!")

    params = %{
      "path" => file_path,
      "old_string" => "world",
      "new_string" => "BOM"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")

    content = File.read!(file_path)
    assert String.starts_with?(content, "\uFEFF")
    assert content == "\uFEFFHello BOM!"
  end

  test "preserves CRLF line endings" do
    file_path = Path.join(@test_dir, "crlf.txt")
    File.write!(file_path, "line1\r\nline2\r\nline3\r\n")

    params = %{
      "path" => file_path,
      "old_string" => "line2",
      "new_string" => "updated_line2"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")

    content = File.read!(file_path)
    assert String.contains?(content, "\r\n")
    assert content == "line1\r\nupdated_line2\r\nline3\r\n"
  end

  test "adapts multi-line old_string to CRLF file" do
    file_path = Path.join(@test_dir, "crlf_multi.txt")
    File.write!(file_path, "aaa\r\nbbb\r\nccc\r\n")

    # Agent sends LF line endings but file uses CRLF
    params = %{
      "path" => file_path,
      "old_string" => "aaa\nbbb",
      "new_string" => "xxx\nyyy"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")
    assert File.read!(file_path) == "xxx\r\nyyy\r\nccc\r\n"
  end

  test "detects and rejects no-change edits" do
    file_path = Path.join(@test_dir, "no_change.txt")
    File.write!(file_path, "Hello world!")

    params = %{
      "path" => file_path,
      "old_string" => "world",
      "new_string" => "world"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert output == "Error: No changes would be made to the file."
  end

  test "normalizes smart quotes in old_string to match ASCII file content" do
    file_path = Path.join(@test_dir, "unicode_normalize.txt")
    File.write!(file_path, "say \"Hello\" - world\n")

    # Agent sends smart quotes and en-dash (common LLM behavior)
    params = %{
      "path" => file_path,
      "old_string" => "say \u201cHello\u201d \u2013 world",
      "new_string" => "say Hi"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")
    assert File.read!(file_path) == "say Hi\n"
  end

  test "does NOT silently transmute file content when old_string differs in Unicode form" do
    file_path = Path.join(@test_dir, "no_transmute.txt")
    # File has smart quotes — these must be preserved if old_string uses ASCII quotes
    File.write!(file_path, "\u201cHello\u201d \u2013 world\n")

    params = %{
      "path" => file_path,
      "old_string" => "\"Hello\" - world",
      "new_string" => "Hi"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    # Should fail because the file has smart quotes but old_string has ASCII quotes.
    # The tool must NOT silently normalize the file content.
    assert output =~ "Error: old_string not found in file."
    # File must be completely untouched
    assert File.read!(file_path) == "\u201cHello\u201d \u2013 world\n"
  end

  test "applies multiple non-overlapping edits in a single call" do
    file_path = Path.join(@test_dir, "multi_edit.txt")
    File.write!(file_path, "one two three four five")

    params = %{
      "path" => file_path,
      "edits" => [
        %{"old_string" => "two", "new_string" => "2"},
        %{"old_string" => "four", "new_string" => "4"}
      ]
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")
    assert File.read!(file_path) == "one 2 three 4 five"
  end

  test "rejects overlapping edits in a single call" do
    file_path = Path.join(@test_dir, "overlap.txt")
    File.write!(file_path, "one two three")

    params = %{
      "path" => file_path,
      "edits" => [
        %{"old_string" => "one two", "new_string" => "1 2"},
        %{"old_string" => "two three", "new_string" => "2 3"}
      ]
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert output =~ "overlap in"
  end

  test "handles concurrent file edits using the mutation queue" do
    file_path = Path.join(@test_dir, "concurrent.txt")
    File.write!(file_path, "a b c d e")

    replacements = [{"a", "1"}, {"b", "2"}, {"c", "3"}, {"d", "4"}, {"e", "5"}]

    tasks =
      Enum.map(replacements, fn {old_char, new_char} ->
        Task.async(fn ->
          # introduce random slight offsets
          Process.sleep(:rand.uniform(20))

          params = %{
            "path" => file_path,
            "old_string" => old_char,
            "new_string" => new_char
          }

          Beamcore.Agent.Tools.Edit.execute(params)
        end)
      end)

    results = Task.await_many(tasks, 10000)

    assert File.read!(file_path) == "1 2 3 4 5"
    assert Enum.all?(results, &String.starts_with?(&1, "Successfully updated"))
  end

  test "preserves trailing newline to prevent line merging" do
    file_path = Path.join(@test_dir, "align_newlines.txt")

    File.write!(
      file_path,
      "defmodule Foo do\n  defp bar do\n  end\n  defp next_func do\n  end\nend\n"
    )

    params = %{
      "path" => file_path,
      "old_string" => "  defp bar do\n  end\n",
      "new_string" => "  defp bar do\n  end\n\n  defp baz do\n  end"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")

    expected =
      "defmodule Foo do\n  defp bar do\n  end\n\n  defp baz do\n  end\n  defp next_func do\n  end\nend\n"

    assert File.read!(file_path) == expected
  end

  test "de-obfuscates Cloudflare email protection placeholders like [email protected] into $@" do
    file_path = Path.join(@test_dir, "deobfuscate.txt")
    File.write!(file_path, "exec \"$@\"\n")

    params = %{
      "path" => file_path,
      "old_string" => "exec \"[email protected]\"",
      "new_string" => "exec \"[email\u00A0protected]\" --debug"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")
    assert File.read!(file_path) == "exec \"$@\" --debug\n"
  end

  test "correctly handles multi-byte UTF-8 characters without corruption" do
    file_path = Path.join(@test_dir, "utf8.txt")
    File.write!(file_path, "Hello 🌍 world\nLine 2 café\nLine 3 naïve\n")

    params = %{
      "path" => file_path,
      "old_string" => "Line 2 café",
      "new_string" => "Line 2 updated"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")
    assert File.read!(file_path) == "Hello 🌍 world\nLine 2 updated\nLine 3 naïve\n"
  end

  test "correctly splices around emoji without byte/codepoint mismatch" do
    file_path = Path.join(@test_dir, "emoji.txt")
    # Emoji are 4-byte UTF-8 sequences — this is where byte vs codepoint bugs show up
    File.write!(file_path, "🎉🎊🎈 party\n🎉🎊🎈 celebration\n")

    params = %{
      "path" => file_path,
      "old_string" => "party",
      "new_string" => "fiesta"
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")
    content = File.read!(file_path)
    assert content == "🎉🎊🎈 fiesta\n🎉🎊🎈 celebration\n"
    # Verify the emoji survived intact
    assert String.valid?(content)
  end

  test "line range disambiguation works correctly with multi-byte characters" do
    file_path = Path.join(@test_dir, "utf8_range.txt")
    # Each emoji is 4 bytes — this exercises the byte-offset line range logic
    File.write!(file_path, "line 1 🎉\nfoo\nline 3 🎊\nfoo\nline 5 🎈\n")

    params = %{
      "path" => file_path,
      "old_string" => "foo",
      "new_string" => "bar",
      "start_line" => 3,
      "end_line" => 4
    }

    output = Beamcore.Agent.Tools.Edit.execute(params)
    assert String.starts_with?(output, "Successfully updated")
    assert File.read!(file_path) == "line 1 🎉\nfoo\nline 3 🎊\nbar\nline 5 🎈\n"
  end
end
