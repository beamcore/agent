defmodule Beamcore.Agent.WorkspaceRootTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.{Git, Make, PathSafety, Read, Write}
  alias Beamcore.Agent.Chat.Session

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcore_workspace_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root = PathSafety.canonical_path(root)

    previous_workspace = Application.get_env(:agent, :workspace_root)
    previous_policy = Application.get_env(:agent, :project_policy_root)
    Application.delete_env(:agent, :project_policy_root)

    on_exit(fn ->
      PathSafety.restore_workspace_root(previous_workspace)
      restore_project_policy_root(previous_policy)
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
                 send(parent, {:workspace, PathSafety.workspace_root(), opts[:workspace_root]})
                 :ok
               end
             )

    assert_receive {:workspace, ^root, ^root}
  end

  test "auto fallback keeps captured workspace root", %{root: root} do
    parent = self()

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok =
               Beamcore.Agent.chat(:auto,
                 workspace_root: root,
                 client: :test_client,
                 supported?: true,
                 tui_start: fn _opts -> raise "alternate screen failed" end,
                 plain_start: fn opts ->
                   send(parent, {:workspace, PathSafety.workspace_root(), opts[:workspace_root]})
                   :ok
                 end
               )
    end)

    assert_receive {:workspace, ^root, ^root}
  end

  test "session detects project nature from captured workspace root", %{root: root} do
    File.write!(Path.join(root, "mix.exs"), "defmodule Demo.MixProject do\nend\n")

    session = Session.new(:client, workspace_root: root)

    assert session.workspace_root == root
    assert session.project_nature == {:elixir, :mix}
  end

  test "file tools resolve inside the configured workspace", %{root: root} do
    with_workspace(root, fn ->
      assert Write.execute(%{"filePath" => "src/demo.txt", "content" => "hello\n"}) =~
               Path.join(root, "src/demo.txt")

      assert File.read!(Path.join(root, "src/demo.txt")) == "hello\n"
      assert Read.execute(%{"filePath" => "src/demo.txt"}) =~ "hello"
      assert {:error, _reason} = PathSafety.resolve("../outside.txt")
    end)
  end

  test "make tool reads the user project Makefile", %{root: root} do
    File.write!(Path.join(root, "Makefile"), ".PHONY: user-target\nuser-target:\n\t@echo user\n")

    with_workspace(root, fn ->
      result = Make.execute(%{"command" => "list"}) |> Jason.decode!()

      assert result["ok"]
      assert result["makefile"] == "Makefile"
      assert result["targets"] == ["user-target"]
    end)
  end

  test "git tool inspects the user project repository", %{root: root} do
    File.write!(Path.join(root, "README.md"), "user repo\n")
    System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)

    with_workspace(root, fn ->
      output = Git.execute(%{"operation" => "status"})

      assert output =~ "README.md"
      refute output =~ "lib/agent.ex"
    end)
  end

  test "ProjectPolicy loads from the user workspace", %{root: root} do
    policy_dir = Path.join(root, ".beamcore")
    File.mkdir_p!(policy_dir)

    File.write!(
      Path.join(policy_dir, "policy.json"),
      Jason.encode!(%{"version" => 1, "deny_paths" => ["secret/**"]})
    )

    with_workspace(root, fn ->
      policy = ProjectPolicy.load()

      assert policy.loaded?
      assert policy.path == Path.join(root, ".beamcore/policy.json")
      assert {:error, _message} = ProjectPolicy.allowed_read_path?(policy, "secret/token.txt")
    end)
  end

  defp with_workspace(root, fun) do
    previous = PathSafety.configure_workspace_root(root)

    try do
      fun.()
    after
      PathSafety.restore_workspace_root(previous)
    end
  end

  defp restore_project_policy_root(nil), do: Application.delete_env(:agent, :project_policy_root)

  defp restore_project_policy_root(root),
    do: Application.put_env(:agent, :project_policy_root, root)
end
