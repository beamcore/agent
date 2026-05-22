defmodule Beamcore.Agent.Tools.GlobTest do
  use ExUnit.Case

  @test_dir "test/tmp_glob_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  test "returns files matching glob" do
    dir = Path.join(@test_dir, "files")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "test1.ex"), "defmodule Test1 do end")
    File.write!(Path.join(dir, "test2.exs"), "defmodule Test2 do end")

    params = %{"pattern" => "**/*.ex", "path" => dir}
    output = Beamcore.Agent.Tools.Glob.execute(params)

    assert String.contains?(output, "test1.ex")
    refute String.contains?(output, "test2.exs")
  end

  test "returns no files found message when glob matches nothing" do
    dir = Path.join(@test_dir, "empty")
    File.mkdir_p!(dir)

    params = %{"pattern" => "**/*.txt", "path" => dir}
    output = Beamcore.Agent.Tools.Glob.execute(params)

    assert String.starts_with?(output, "No files found matching pattern:")
  end

  test "uses current working directory by default" do
    params = %{"pattern" => "lib/**/*.ex"}
    output = Beamcore.Agent.Tools.Glob.execute(params)

    # It should find at least one file since agent has lib/agent/tools/*.ex
    assert String.contains?(output, "agent")
    assert String.contains?(output, ".ex")
  end

  test "glob respects .gitignore" do
    dir = Path.join(@test_dir, "gitignore")
    File.mkdir_p!(dir)

    System.cmd("git", ["init"], cd: dir)
    File.write!(Path.join(dir, ".gitignore"), "ignored.ex")

    File.write!(Path.join(dir, "ignored.ex"), "defmodule Ignored do end")
    File.write!(Path.join(dir, "visible.ex"), "defmodule Visible do end")

    params = %{"pattern" => "*.ex", "path" => dir}
    output = Beamcore.Agent.Tools.Glob.execute(params)

    assert String.contains?(output, "visible.ex")
    refute String.contains?(output, "ignored.ex")

    # Show all should reveal it
    params = %{"pattern" => "*.ex", "path" => dir, "all" => true}
    output = Beamcore.Agent.Tools.Glob.execute(params)
    assert String.contains?(output, "ignored.ex")
  end

  test "rejects absolute paths" do
    output = Beamcore.Agent.Tools.Glob.execute(%{"pattern" => "*.ex", "path" => "/tmp"})

    assert output =~ "absolute paths are not allowed"
  end

  test "rejects path traversal" do
    output = Beamcore.Agent.Tools.Glob.execute(%{"pattern" => "*.ex", "path" => "../"})

    assert output =~ "path traversal is not allowed"
  end
end
