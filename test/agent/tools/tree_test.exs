defmodule Beamcore.Agent.Tools.TreeTest do
  use ExUnit.Case
  alias Beamcore.Agent.Tools.Tree

  setup do
    dir = "test/tmp_tree_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  test "tree ignores .git and deps by default", %{dir: dir} do
    # Create some files and directories
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join([dir, "src", "main.ex"]), "main")

    File.mkdir_p!(Path.join(dir, ".git"))
    File.mkdir_p!(Path.join(dir, "deps"))
    File.write!(Path.join(dir, "README.md"), "readme")

    params = %{"path" => dir}
    output = Tree.execute(params)

    assert String.contains?(output, "src/")
    assert String.contains?(output, "main.ex")
    assert String.contains?(output, "README.md")

    refute String.contains?(output, ".git/")
    refute String.contains?(output, "deps/")
  end

  test "tree shows all files when all: true", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "src"))
    File.mkdir_p!(Path.join(dir, ".git"))
    File.mkdir_p!(Path.join(dir, "deps"))

    params = %{"path" => dir, "all" => true}
    output = Tree.execute(params)

    assert String.contains?(output, "src/")
    assert String.contains?(output, ".git/")
    assert String.contains?(output, "deps/")
  end

  test "tree respects depth parameter", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join([dir, "src", "main.ex"]), "main")
    File.write!(Path.join(dir, "README.md"), "readme")

    # Depth 1 should show src/ but not its contents
    params = %{"path" => dir, "depth" => 1}
    output = Tree.execute(params)

    assert String.contains?(output, "src/")
    refute String.contains?(output, "main.ex")
    assert String.contains?(output, "README.md")
  end

  test "tree respects .gitignore", %{dir: dir} do
    # Initialize a git repo in the temp dir
    System.cmd("git", ["init"], cd: dir)
    File.write!(Path.join(dir, ".gitignore"), "ignored_dir/\n*.log")

    File.mkdir_p!(Path.join(dir, "ignored_dir"))
    File.write!(Path.join([dir, "ignored_dir", "secret.txt"]), "secret")
    File.write!(Path.join(dir, "test.log"), "log")
    File.write!(Path.join(dir, "visible.txt"), "visible")

    params = %{"path" => dir}
    output = Tree.execute(params)

    assert String.contains?(output, "visible.txt")
    refute String.contains?(output, "ignored_dir/")
    refute String.contains?(output, "test.log")

    # Show all should reveal them
    params = %{"path" => dir, "all" => true}
    output = Tree.execute(params)
    assert String.contains?(output, "ignored_dir/")
    assert String.contains?(output, "test.log")
  end

  test "tree rejects absolute paths" do
    output = Tree.execute(%{"path" => "/tmp"})

    assert output =~ "absolute paths are not allowed"
  end

  test "tree rejects path traversal" do
    output = Tree.execute(%{"path" => "../"})

    assert output =~ "path traversal is not allowed"
  end
end
