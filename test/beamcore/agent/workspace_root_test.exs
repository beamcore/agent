defmodule Beamcore.Agent.WorkspaceRootTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Tools.PathInput
  alias Beamcore.Agent.Tools.Eeva

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcore_workspace_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root = PathInput.canonical_path(root)

    previous_workspace = Application.get_env(:agent, :workspace_root)

    on_exit(fn ->
      PathInput.restore_workspace_root(previous_workspace)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "chat startup captures launch workspace root", %{root: root} do
    parent = self()

    assert :ok =
             Beamcore.Agent.chat(:plain,
               workspace_root: root,
               client: :test_client,
               plain_start: fn opts ->
                 send(parent, {:workspace, PathInput.workspace_root(), opts[:workspace_root]})
                 :ok
               end
             )

    assert_receive {:workspace, ^root, ^root}
  end

  test "session detects project nature from captured workspace root", %{root: root} do
    File.write!(Path.join(root, "mix.exs"), "defmodule Demo.MixProject do\nend\n")
    session = Session.new(:client, workspace_root: root)
    assert session.workspace_root == root
    assert session.project_nature == {:elixir, :mix}
  end

  test "ordinary Eeva File calls run inside the selected workspace", %{root: root} do
    with_workspace(root, fn ->
      result =
        Eeva.execute(%{
          "code" =>
            "File.mkdir_p!(\"src\"); File.write!(\"src/demo.txt\", \"hello\\n\"); File.read!(\"src/demo.txt\")"
        })
        |> Jason.decode!()

      assert result["ok"]
      assert result["result"] =~ "hello"
      assert File.read!(Path.join(root, "src/demo.txt")) == "hello\n"
      assert {:ok, outside} = PathInput.resolve("../outside.txt")
      assert outside == Path.join(Path.dirname(root), "outside.txt")
    end)
  end

  test "ordinary Eeva System.cmd inspects the user repository", %{root: root} do
    File.write!(Path.join(root, "README.md"), "user repo\n")
    System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)

    with_workspace(root, fn ->
      result =
        Eeva.execute(%{
          "code" => "System.cmd(\"git\", [\"status\", \"--short\"], stderr_to_stdout: true)"
        })
        |> Jason.decode!()

      assert result["ok"]
      assert result["result"] =~ "README.md"
    end)
  end

  defp with_workspace(root, fun) do
    previous = PathInput.configure_workspace_root(root)

    try do
      fun.()
    after
      PathInput.restore_workspace_root(previous)
    end
  end
end
