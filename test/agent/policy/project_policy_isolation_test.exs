defmodule Beamcore.Agent.Policy.ProjectPolicyIsolationTest do
  use ExUnit.Case

  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Chat.ToolPolicy

  test "configured test policy root ignores policy files in the current working directory" do
    fake_runtime_root = Beamcore.Agent.TestPolicyRoot.temp_root("beamcore_fake_runtime")
    isolated_root = Beamcore.Agent.TestPolicyRoot.temp_root("beamcore_isolated_policy")
    previous = File.cwd!()

    File.mkdir_p!(Path.join(fake_runtime_root, ".beamcore"))
    File.mkdir_p!(Path.join(isolated_root, ".beamcore"))

    File.write!(
      Path.join(fake_runtime_root, ".beamcore/policy.json"),
      Jason.encode!(%{version: 1, deny_paths: ["scratch/**"]})
    )

    File.cd!(fake_runtime_root)

    try do
      Beamcore.Agent.TestPolicyRoot.with_root(isolated_root, fn ->
        policy = ProjectPolicy.load()

        refute policy.loaded?
        assert :ok == ProjectPolicy.allowed_write_path?(policy, "scratch/a.ex")
      end)
    after
      File.cd!(previous)
      File.rm_rf!(fake_runtime_root)
      File.rm_rf!(isolated_root)
    end
  end

  test "tool policy uses configured test policy root instead of current working directory" do
    fake_runtime_root = Beamcore.Agent.TestPolicyRoot.temp_root("beamcore_fake_runtime_tool")
    isolated_root = Beamcore.Agent.TestPolicyRoot.temp_root("beamcore_isolated_policy_tool")
    previous = File.cwd!()

    File.mkdir_p!(Path.join(fake_runtime_root, ".beamcore"))
    File.mkdir_p!(Path.join(isolated_root, ".beamcore"))

    File.write!(
      Path.join(fake_runtime_root, ".beamcore/policy.json"),
      Jason.encode!(%{version: 1, tool_permissions: %{make: "deny"}})
    )

    File.cd!(fake_runtime_root)

    try do
      Beamcore.Agent.TestPolicyRoot.with_root(isolated_root, fn ->
        assert :ok ==
                 ToolPolicy.allow_tool_call(ToolPolicy.default(), "make", %{"command" => "list"})
      end)
    after
      File.cd!(previous)
      File.rm_rf!(fake_runtime_root)
      File.rm_rf!(isolated_root)
    end
  end

  test "policy in the configured test workspace is still enforced when intended" do
    isolated_root = Beamcore.Agent.TestPolicyRoot.temp_root("beamcore_enforced_policy")

    File.mkdir_p!(Path.join(isolated_root, ".beamcore"))

    File.write!(
      Path.join(isolated_root, ".beamcore/policy.json"),
      Jason.encode!(%{version: 1, deny_paths: ["scratch/**"]})
    )

    try do
      Beamcore.Agent.TestPolicyRoot.with_root(isolated_root, fn ->
        policy = ProjectPolicy.load()

        assert policy.loaded?
        assert {:error, message} = ProjectPolicy.allowed_write_path?(policy, "scratch/a.ex")
        assert message =~ "deny_paths"
      end)
    after
      File.rm_rf!(isolated_root)
    end
  end
end
