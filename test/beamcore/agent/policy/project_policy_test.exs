defmodule Beamcore.Agent.Policy.ProjectPolicyTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.PathSafety
  alias Beamcore.Agent.Policy.ProjectPolicy

  setup do
    root = Path.join(System.tmp_dir!(), "beamcore_policy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = PathSafety.configure_workspace_root(root)

    on_exit(fn ->
      PathSafety.restore_workspace_root(previous)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "only eeva is a known project tool" do
    assert ProjectPolicy.known_tools() == ["eeva"]
    assert ProjectPolicy.permissions() == ["allow", "deny"]
  end

  test "default example policy allows eeva", %{root: root} do
    assert {:ok, policy} = ProjectPolicy.init(root)
    assert policy.tool_permissions["eeva"] == "allow"
  end

  test "project policy can deny eeva", %{root: root} do
    policy =
      ProjectPolicy.default(root)
      |> Map.put(:loaded?, true)
      |> ProjectPolicy.set_tool_permission("eeva", "deny")

    assert {:ok, _} = ProjectPolicy.save(root, policy)

    assert ProjectPolicy.allowed_tool_names(
             ["eeva"],
             ToolPolicy.default(),
             ProjectPolicy.load(root)
           ) == []
  end

  test "allow_write_paths permits creating the parent of a recursive pattern", %{root: root} do
    policy =
      ProjectPolicy.default(root)
      |> Map.put(:loaded?, true)
      |> Map.put(:allow_write_paths, ["allowed/**"])

    assert {:ok, _} = ProjectPolicy.save(root, policy)
    assert :ok == ProjectPolicy.allowed_write_path?(ProjectPolicy.load(root), "allowed")
    assert :ok == ProjectPolicy.allowed_write_path?(ProjectPolicy.load(root), "allowed/file.txt")
    assert {:error, _} = ProjectPolicy.allowed_write_path?(ProjectPolicy.load(root), "other.txt")
  end

end
