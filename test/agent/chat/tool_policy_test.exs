defmodule Beamcore.Agent.Chat.ToolPolicyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy

  test "detects read-only requests" do
    policy = ToolPolicy.from_user_message("Read-only smoke test. Do not modify files.")

    assert policy.mode == :read_only
    refute policy.allow_task
  end

  test "allows task only when explicitly requested in normal mode" do
    policy = ToolPolicy.from_user_message("Use task delegation to inspect the codebase.")

    assert policy.mode == :normal
    assert policy.allow_task
    refute policy.allow_network
  end

  test "allows network only when explicitly requested" do
    default_policy = ToolPolicy.from_user_message("Inspect local files.")
    network_policy = ToolPolicy.from_user_message("Fetch https://example.com with curl.")

    refute default_policy.allow_network
    assert network_policy.allow_network
  end

  test "read-only policy blocks mutating tools" do
    policy = ToolPolicy.from_user_message("Do not modify files.")

    for tool <- ~w(write edit patch fs curl task) do
      assert {:error, message} = ToolPolicy.allow_tool_call(policy, tool, %{})
      assert message =~ "read-only policy"
    end
  end

  test "read-only policy allows safe git operations only" do
    policy = ToolPolicy.from_user_message("Read-only audit.")

    assert :ok == ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "status"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "diff"})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "commit"})

    assert message =~ "git operation"
  end

  test "read-only policy allows validate but blocks mutating mix commands" do
    policy = ToolPolicy.from_user_message("Read-only validation.")

    assert :ok == ToolPolicy.allow_tool_call(policy, "mix", %{"command" => "validate"})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "mix", %{"command" => "format"})

    assert message =~ "mix command"
  end
end
