defmodule Beamcore.Agent.Tools.PathSafetyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.PathSafety

  test "resolves safe relative paths inside the workspace" do
    assert {:ok, path} = PathSafety.resolve("README.md")
    assert path == Path.expand("README.md")

    assert {:ok, nested_path} = PathSafety.resolve("lib/agent/openai.ex")
    assert nested_path == Path.expand("lib/agent/openai.ex")
  end

  test "rejects absolute paths" do
    assert {:error, reason} = PathSafety.resolve("/etc/passwd")
    assert reason =~ "absolute paths are not allowed"

    assert {:error, reason} = PathSafety.resolve("/tmp/file.txt", allow_missing: true)
    assert reason =~ "absolute paths are not allowed"
  end

  test "rejects path traversal" do
    assert {:error, reason} = PathSafety.resolve("../secret.txt")
    assert reason =~ "path traversal is not allowed"

    assert {:error, reason} = PathSafety.resolve("../../etc/passwd")
    assert reason =~ "path traversal is not allowed"
  end

  test "allows missing files inside workspace when requested" do
    assert {:ok, path} = PathSafety.resolve("test/tmp_missing_file.txt", allow_missing: true)
    assert path == Path.expand("test/tmp_missing_file.txt")
  end

  test "rejects symlink escapes" do
    workspace_link = "test/tmp_path_safety_link"

    outside_dir =
      Path.join(System.tmp_dir!(), "agent_path_safety_#{System.unique_integer([:positive])}")

    File.rm_rf!(workspace_link)
    File.rm_rf!(outside_dir)
    File.mkdir_p!(outside_dir)

    try do
      case File.ln_s(outside_dir, workspace_link) do
        :ok ->
          assert {:error, reason} =
                   PathSafety.resolve(Path.join(workspace_link, "outside.txt"),
                     allow_missing: true
                   )

          assert reason =~ "path outside workspace"

        {:error, :enotsup} ->
          :ok
      end
    after
      File.rm_rf!(workspace_link)
      File.rm_rf!(outside_dir)
    end
  end
end
