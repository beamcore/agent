defmodule Beamcore.Agent.Tools.GitTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Git

  test "status operation returns git status" do
    params = %{"operation" => "status"}
    output = Git.execute(params)
    # Output might vary depending on git version and state, but "On branch" or "HEAD" is common.
    assert String.contains?(output, "On branch") || String.contains?(output, "HEAD")
  end

  test "log operation returns 2 latest commits" do
    params = %{"operation" => "log"}
    output = Git.execute(params)
    # Check for typical git log output
    assert String.contains?(output, "commit")
    # Verify it has at most 2 commits
    lines = String.split(output, "\n")
    commit_lines = Enum.filter(lines, &String.starts_with?(&1, "commit "))
    assert length(commit_lines) > 0
    assert length(commit_lines) <= 2
  end

  test "diff operation returns git diff" do
    params = %{"operation" => "diff"}
    output = Git.execute(params)
    # If no changes, returns "Success (no output)"
    assert output == "Success (no output)" || String.contains?(output, "diff --git")
  end

  test "restore operation requires path" do
    params = %{"operation" => "restore"}
    output = Git.execute(params)
    assert output == "Error: path is required for restore operation."
  end

  test "unsupported operation returns error" do
    params = %{"operation" => "invalid"}
    # The Enum in spec would normally prevent this if called via LLM, 
    # but execute should handle it.
    # Actually my execute has a _ -> error clause.
    # But wait, case operation do ... _ -> error end
    # I'll check my code.
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
