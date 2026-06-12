defmodule Beamcore.Agent.Tools.PathInputTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Tools.PathInput

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcore_path_input_#{System.unique_integer([:positive])}")

    outside =
      Path.join(
        System.tmp_dir!(),
        "beamcore_path_input_outside_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    root = PathInput.canonical_path(root)
    outside = PathInput.canonical_path(outside)
    previous = PathInput.configure_workspace_root(root)

    on_exit(fn ->
      PathInput.restore_workspace_root(previous)
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    %{root: root, outside: outside}
  end

  test "resolves relative paths from the configured project root", %{root: root} do
    assert {:ok, path} = PathInput.resolve("lib/example.ex")
    assert path == Path.join(root, "lib/example.ex")
  end

  test "allows absolute paths", %{outside: outside} do
    path = Path.join(outside, "note.txt")
    assert {:ok, ^path} = PathInput.resolve(path)
  end

  test "allows parent directory segments as normal local path navigation", %{root: root} do
    parent = Path.dirname(root)
    assert {:ok, path} = PathInput.resolve("../outside.txt")
    assert path == Path.join(parent, "outside.txt")
  end

  test "allows symlink paths where the platform supports them", %{root: root, outside: outside} do
    target = Path.join(outside, "target.txt")
    link = Path.join(root, "linked.txt")
    File.write!(target, "outside\n")

    case File.ln_s(target, link) do
      :ok ->
        assert {:ok, ^link} = PathInput.resolve("linked.txt")
        assert File.read!(link) == "outside\n"

      {:error, :enotsup} ->
        :ok
    end
  end

  test "display key is relative inside project and absolute outside", %{
    root: root,
    outside: outside
  } do
    assert PathInput.display_key(Path.join(root, "src/a.ex"), root) == "src/a.ex"
    assert PathInput.display_key(Path.join(outside, "a.ex"), root) == Path.join(outside, "a.ex")
  end

  test "validate_pattern only rejects non-string patterns" do
    assert :ok == PathInput.validate_pattern("../**/*")
    assert :ok == PathInput.validate_pattern("/tmp/**/*")
    assert {:error, reason} = PathInput.validate_pattern(:not_a_pattern)
    assert reason =~ "pattern must be a string"
  end

  test "gitignores_for_path and ignored? work correctly" do
    dir = Path.join(PathInput.workspace_root(), "tmp_path_input_test")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, ".gitignore"), "# Comment\nignored_file.ex\nignored_dir/\n")

    ignores = PathInput.gitignores_for_path(dir)

    assert MapSet.member?(ignores, "ignored_file.ex")
    assert MapSet.member?(ignores, "ignored_dir")

    assert PathInput.ignored?(Path.join(dir, "ignored_file.ex"), dir, ignores)
    assert PathInput.ignored?(Path.join(dir, "ignored_dir/some_file.ex"), dir, ignores)
    refute PathInput.ignored?(Path.join(dir, "visible_file.ex"), dir, ignores)
  end

  test "gitignores_for_path and ignored? with wildcards" do
    dir = Path.join(PathInput.workspace_root(), "tmp_path_input_wildcard_test")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, ".gitignore"), "*.log\nsrc/secret_*.ex\n")

    ignores = PathInput.gitignores_for_path(dir)

    assert PathInput.ignored?(Path.join(dir, "test.log"), dir, ignores)
    assert PathInput.ignored?(Path.join(dir, "nested/test.log"), dir, ignores)
    assert PathInput.ignored?(Path.join(dir, "src/secret_code.ex"), dir, ignores)
    assert PathInput.ignored?(Path.join(dir, "src/secret_code.ex/nested.txt"), dir, ignores)
    refute PathInput.ignored?(Path.join(dir, "src/normal.ex"), dir, ignores)
  end
end
