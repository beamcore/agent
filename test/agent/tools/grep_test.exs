defmodule Beamcore.Agent.Tools.GrepTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Grep
  @test_dir "test/tmp_grep_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  test "spec/0 returns the expected tool specification" do
    spec = Grep.spec()
    assert spec.type == "function"
    assert spec.function.name == "grep"
    assert "pattern" in spec.function.parameters.required
    assert :offset in Map.keys(spec.function.parameters.properties)
    assert :limit in Map.keys(spec.function.parameters.properties)
  end

  test "execute/1 finds matches in a file" do
    params = %{
      "pattern" => "ELIXIR_IS_AWESOME",
      "path" => "test/testfile.txt"
    }

    output = Grep.execute(params)
    assert output =~ "testfile.txt"
    assert output =~ "2:This is line 2 with a special keyword: ELIXIR_IS_AWESOME"
    assert output =~ "4:Line 4 also has ELIXIR_IS_AWESOME"
    assert output =~ "(2 matches found. End of matches.)"
  end

  test "execute/1 respects offset and limit parameters in grep" do
    params = %{
      "pattern" => "ELIXIR_IS_AWESOME",
      "path" => "test/testfile.txt",
      "offset" => 2,
      "limit" => 1
    }

    output = Grep.execute(params)
    refute output =~ "2:This is line 2 with a special keyword"
    assert output =~ "4:Line 4 also has ELIXIR_IS_AWESOME"
    assert output =~ "(2 matches found. End of matches.)"
  end

  test "execute/1 respects offset and limit parameters in grep with matches left" do
    params = %{
      "pattern" => "ELIXIR_IS_AWESOME",
      "path" => "test/testfile.txt",
      "offset" => 1,
      "limit" => 1
    }

    output = Grep.execute(params)
    assert output =~ "2:This is line 2 with a special keyword"
    refute output =~ "4:Line 4 also has ELIXIR_IS_AWESOME"
    assert output =~ "(Showing matches 1-1. 1 matches left. Use offset=2 to continue.)"
  end

  test "execute/1 returns no matches found when there are no matches" do
    params = %{
      "pattern" => "NON_EXISTENT_PATTERN_12345",
      "path" => "test/testfile.txt"
    }

    output = Grep.execute(params)
    assert output == "No matches found."
  end

  test "execute/1 supports the include parameter" do
    params = %{
      "pattern" => "ELIXIR_IS_AWESOME",
      "path" => "test",
      "include" => "*.txt"
    }

    output = Grep.execute(params)
    assert output =~ "testfile.txt"
    assert output =~ "ELIXIR_IS_AWESOME"
  end

  test "grep respects .gitignore" do
    dir = Path.join(@test_dir, "gitignore")
    File.mkdir_p!(dir)

    System.cmd("git", ["init"], cd: dir)
    File.write!(Path.join(dir, ".gitignore"), "ignored.txt")

    File.write!(Path.join(dir, "ignored.txt"), "search me")
    File.write!(Path.join(dir, "visible.txt"), "search me")

    params = %{"pattern" => "search me", "path" => dir}
    output = Grep.execute(params)

    assert output =~ "visible.txt"
    refute output =~ "ignored.txt"

    # Even with include, it should respect it
    params = %{"pattern" => "search me", "path" => dir, "include" => "*.txt"}
    output = Grep.execute(params)
    assert output =~ "visible.txt"
    refute output =~ "ignored.txt"

    # Show all should reveal it
    params = %{"pattern" => "search me", "path" => dir, "all" => true}
    output = Grep.execute(params)
    assert output =~ "ignored.txt"
  end

  test "rejects absolute paths" do
    output = Grep.execute(%{"pattern" => "anything", "path" => "/tmp"})

    assert output =~ "absolute paths are not allowed"
  end

  test "rejects path traversal" do
    output = Grep.execute(%{"pattern" => "anything", "path" => "../"})

    assert output =~ "path traversal is not allowed"
  end
end
