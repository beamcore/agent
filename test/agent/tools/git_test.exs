defmodule Beamcore.Agent.Tools.GitTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Git

  test "status operation returns git status" do
    params = %{"operation" => "status"}
    output = Git.execute(params)
    assert String.contains?(output, "On branch") || String.contains?(output, "HEAD")
  end

  test "log operation returns 2 latest commits" do
    params = %{"operation" => "log", "limit" => 2}
    output = Git.execute(params)
    assert String.contains?(output, "commit")
    lines = String.split(output, "\n")
    commit_lines = Enum.filter(lines, &String.starts_with?(&1, "commit "))
    assert length(commit_lines) > 0
    assert length(commit_lines) <= 2
  end

  test "log operation with custom limit works" do
    params = %{"operation" => "log", "limit" => 1}
    output = Git.execute(params)
    assert String.contains?(output, "commit")
    lines = String.split(output, "\n")
    commit_lines = Enum.filter(lines, &String.starts_with?(&1, "commit "))
    assert length(commit_lines) == 1
  end

  test "diff operation returns git diff" do
    params = %{"operation" => "diff"}
    output = Git.execute(params)
    assert output == "Success (no output)" || String.contains?(output, "diff --git")
  end

  test "diff operation with base revision works" do
    params = %{"operation" => "diff", "base" => "HEAD"}
    output = Git.execute(params)
    assert output == "Success (no output)" || String.contains?(output, "diff --git")
  end

  test "rejects option injection in base revision" do
    params = %{"operation" => "diff", "base" => "--dry-run"}
    output = Git.execute(params)
    assert output =~ "revision cannot start with '-'"
  end

  test "restore operation requires path" do
    params = %{"operation" => "restore"}
    output = Git.execute(params)
    assert output == "Error: path is required for restore operation."
  end

  test "clone operation requires url" do
    params = %{"operation" => "clone"}
    output = Git.execute(params)
    assert output == "Error: url is required for clone operation."
  end

  test "commit operation requires message" do
    params = %{"operation" => "commit"}
    output = Git.execute(params)
    assert output == "Error: message is required for commit operation."
  end

  test "commit operation works or handles clean working tree gracefully" do
    workdir = "tmp/git_tool_commit_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(workdir)

    try do
      System.cmd("git", ["init"], cd: workdir)
      File.write!(Path.join(workdir, "tracked.txt"), "hello\n")
      System.cmd("git", ["add", "tracked.txt"], cd: workdir)

      params = %{
        "operation" => "commit",
        "message" => "test commit",
        "workdir" => workdir
      }

      output = Git.execute(params)

      assert String.contains?(output, "Success") ||
               String.contains?(output, "test commit") ||
               String.contains?(output, "nothing to commit") ||
               String.contains?(output, "nothing added to commit") ||
               String.contains?(output, "no changes added to commit")
    after
      File.rm_rf!(workdir)
    end
  end

  test "unsupported operation returns error" do
    params = %{"operation" => "invalid"}
    output = Git.execute(params)
    assert output == "Error: Unsupported git operation: invalid"
  end

  test "rejects absolute workdir" do
    output = Git.execute(%{"operation" => "status", "workdir" => "/tmp"})
    assert output =~ "absolute paths are not allowed"
  end

  test "rejects path traversal in path arguments" do
    output = Git.execute(%{"operation" => "diff", "path" => "../outside.txt"})
    assert output =~ "path traversal is not allowed"
  end
end
