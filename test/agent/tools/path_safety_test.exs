defmodule Beamcore.Agent.Tools.PathSafetyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.PathSafety

  test "resolves safe relative paths inside the workspace" do
    assert {:ok, path} = PathSafety.resolve("README.md")
    assert path == Path.expand("README.md")

    assert {:ok, nested_path} = PathSafety.resolve("lib/agent/openai.ex")
    assert nested_path == Path.expand("lib/agent/openai.ex")
  end

  test "tolerates leading slash and absolute workspace root paths" do
    root = PathSafety.workspace_root()
    assert {:ok, path1} = PathSafety.resolve("/")
    assert path1 == root

    assert {:ok, path2} = PathSafety.resolve(root)
    assert path2 == root

    assert {:ok, path3} = PathSafety.resolve(Path.join(root, "README.md"))
    assert path3 == Path.expand("README.md")
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

  test "gitignores_for_path and ignored? work correctly" do
    dir = "test/tmp_path_safety_test"
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    # Create dummy gitignore
    File.write!(Path.join(dir, ".gitignore"), "# Comment\nignored_file.ex\nignored_dir/\n")

    ignores = PathSafety.gitignores_for_path(dir)

    assert MapSet.member?(ignores, "ignored_file.ex")
    assert MapSet.member?(ignores, "ignored_dir")

    assert PathSafety.ignored?(Path.join(dir, "ignored_file.ex"), dir, ignores)
    assert PathSafety.ignored?(Path.join(dir, "ignored_dir/some_file.ex"), dir, ignores)
    refute PathSafety.ignored?(Path.join(dir, "visible_file.ex"), dir, ignores)
  end

  test "gitignores_for_path and ignored? with wildcards" do
    dir = "test/tmp_path_safety_wildcard_test"
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, ".gitignore"), "*.log\nsrc/secret_*.ex\n")

    ignores = PathSafety.gitignores_for_path(dir)

    assert PathSafety.ignored?(Path.join(dir, "test.log"), dir, ignores)
    assert PathSafety.ignored?(Path.join(dir, "nested/test.log"), dir, ignores)
    assert PathSafety.ignored?(Path.join(dir, "src/secret_code.ex"), dir, ignores)
    assert PathSafety.ignored?(Path.join(dir, "src/secret_code.ex/nested.txt"), dir, ignores)
    refute PathSafety.ignored?(Path.join(dir, "src/normal.ex"), dir, ignores)
  end
end
