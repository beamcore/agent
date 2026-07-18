defmodule Beamcore.Agent.Tools.Eeva.WriteHelperTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Tools.Eeva.WriteHelper

  setup do
    dir = Path.join(System.tmp_dir!(), "write_helper_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  describe "write!/3 with binary content" do
    test "writes binary string to file", %{dir: dir} do
      path = Path.join(dir, "test.txt")
      WriteHelper.write!(path, "hello world")
      assert File.read!(path) == "hello world"
    end

    test "creates parent directories", %{dir: dir} do
      path = Path.join(dir, "sub/dir/deep/file.txt")
      WriteHelper.write!(path, "nested")
      assert File.read!(path) == "nested"
    end

    test "overwrites existing file", %{dir: dir} do
      path = Path.join(dir, "overwrite.txt")
      WriteHelper.write!(path, "first")
      WriteHelper.write!(path, "second")
      assert File.read!(path) == "second"
    end

    test "passes options through to File.write", %{dir: dir} do
      path = Path.join(dir, "append.txt")
      WriteHelper.write!(path, "line1\n")
      WriteHelper.write!(path, "line2\n", [:append])
      assert File.read!(path) == "line1\nline2\n"
    end
  end

  describe "write!/3 with list content" do
    test "joins list of strings with newlines", %{dir: dir} do
      path = Path.join(dir, "lines.txt")
      WriteHelper.write!(path, ["line1", "line2", "line3"])
      assert File.read!(path) == "line1\nline2\nline3"
    end

    test "handles single-element list", %{dir: dir} do
      path = Path.join(dir, "single.txt")
      WriteHelper.write!(path, ["only line"])
      assert File.read!(path) == "only line"
    end

    test "handles empty list", %{dir: dir} do
      path = Path.join(dir, "empty.txt")
      WriteHelper.write!(path, [])
      assert File.read!(path) == ""
    end

    test "creates parent directories for list content", %{dir: dir} do
      path = Path.join(dir, "nested/list/file.txt")
      WriteHelper.write!(path, ["a", "b"])
      assert File.read!(path) == "a\nb"
    end

    test "list content with special characters preserved", %{dir: dir} do
      path = Path.join(dir, "special.txt")

      lines = [
        "#!/bin/bash",
        "echo \"Hello World\"",
        "echo \"Line with $VAR\"",
        "path=\"C:\\Users\\test\""
      ]

      WriteHelper.write!(path, lines)
      content = File.read!(path)
      assert content =~ "#!/bin/bash"
      assert content =~ "echo \"Hello World\""
      assert content =~ "echo \"Line with $VAR\""
      assert content =~ "path=\"C:\\Users\\test\""
    end

    test "list content preserves quotes and backslashes literally", %{dir: dir} do
      path = Path.join(dir, "literal.txt")

      lines = [
        "regex = /\\d{4}-\\d{2}-\\d{2}/",
        "msg = \"He said \\\"hello\\\"\""
      ]

      WriteHelper.write!(path, lines)
      content = File.read!(path)
      assert content =~ ~S|regex = /\d{4}-\d{2}-\d{2}/|
      assert content =~ ~S|msg = "He said \"hello\""|
    end
  end

  describe "write!/3 with other content types" do
    test "converts atom to string", %{dir: dir} do
      path = Path.join(dir, "atom.txt")
      WriteHelper.write!(path, :hello)
      assert File.read!(path) == "hello"
    end

    test "converts integer to string", %{dir: dir} do
      path = Path.join(dir, "int.txt")
      WriteHelper.write!(path, 42)
      assert File.read!(path) == "42"
    end
  end

  describe "write/3 (non-bang version)" do
    test "returns :ok on success", %{dir: dir} do
      path = Path.join(dir, "ok.txt")
      assert :ok = WriteHelper.write(path, "content")
    end

    test "returns :ok for list content", %{dir: dir} do
      path = Path.join(dir, "ok_list.txt")
      assert :ok = WriteHelper.write(path, ["a", "b"])
    end

    test "returns error for invalid path", %{dir: _dir} do
      result = WriteHelper.write("/nonexistent/deeply/nested/path/file.txt", "content")
      assert {:error, _} = result
    end
  end

  describe "exact edits" do
    test "replaces a unique anchor with literal payload content", %{dir: dir} do
      path = Path.join(dir, "module.ex")
      original = "defmodule Demo do\n  def old, do: :old\nend\n"
      interpolation = "#" <> "{literal}"
      replacement = "  def value, do: \"#{interpolation}\"\\\\path"
      File.write!(path, original)

      assert :ok = WriteHelper.replace!(path, "  def old, do: :old", replacement)
      assert File.read!(path) == String.replace(original, "  def old, do: :old", replacement)
    end

    test "validates every anchor before writing", %{dir: dir} do
      path = Path.join(dir, "atomic.txt")
      original = "one\ntwo\n"
      File.write!(path, original)

      assert_raise ArgumentError, ~r/edit anchor was not found/, fn ->
        WriteHelper.edit!(path, [{"one", "changed"}, {"missing", "never written"}])
      end

      assert File.read!(path) == original
    end

    test "rejects an ambiguous anchor without changing the file", %{dir: dir} do
      path = Path.join(dir, "ambiguous.txt")
      original = "same\nsame\n"
      File.write!(path, original)

      assert_raise ArgumentError, ~r/matched 2 times/, fn ->
        WriteHelper.replace!(path, "same", "changed")
      end

      assert File.read!(path) == original
    end
  end

  describe "escaping scenarios that trip up LLMs" do
    test "bash script with shebang and echo", %{dir: dir} do
      path = Path.join(dir, "script.sh")
      # This is the pattern LLMs should use - list of lines
      lines = [
        "#!/bin/bash",
        "echo \"Hello World\"",
        "echo \"Line 2\""
      ]

      WriteHelper.write!(path, lines)
      content = File.read!(path)
      assert content =~ "#!/bin/bash"
      assert content =~ "echo \"Hello World\""
    end

    test "python script with f-string", %{dir: dir} do
      path = Path.join(dir, "script.py")

      lines = [
        "import sys",
        "name = sys.argv[1]",
        "print(f\"Hello, {name}!\")"
      ]

      WriteHelper.write!(path, lines)
      content = File.read!(path)
      assert content =~ "print(f\"Hello, {name}!\")"
    end

    test "javascript with template literal", %{dir: dir} do
      path = Path.join(dir, "script.js")

      lines = [
        "const name = 'world';",
        "console.log(`Hello, ${name}!`);"
      ]

      WriteHelper.write!(path, lines)
      content = File.read!(path)
      assert content =~ "${name}"
    end

    test "elixir config with string interpolation", %{dir: dir} do
      path = Path.join(dir, "config.exs")
      # For Elixir content that NEEDS interpolation, use binary directly
      content = """
      import Config
      config :my_app, name: "world"
      """

      WriteHelper.write!(path, content)
      assert File.read!(path) =~ "config :my_app"
    end
  end
end
