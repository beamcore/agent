defmodule Beamcore.Agent.Chat.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.ToolPolicy

  test "default policy exposes only eeva" do
    assert ToolPolicy.allowed_tool_names(ToolPolicy.default()) == ["eeva"]
    assert :ok == ToolPolicy.allow_tool_call(ToolPolicy.default(), "eeva", %{"code" => "1 + 1"})
  end

  test "unknown legacy tools are always rejected" do
    for name <- ~w(read grep modify_file git test_tool task plan memory reflect image_generation) do
      assert {:error, message} = ToolPolicy.allow_tool_call(ToolPolicy.default(), name, %{})
      assert message =~ "only eeva"
    end
  end

  test "chat mode exposes eeva for safe memory-only work" do
    policy = ToolPolicy.chat()
    assert ToolPolicy.allowed_tool_names(policy) == ["eeva"]
    assert :ok == ToolPolicy.allow_tool_call(policy, "eeva", %{"code" => "Beamcore.Memory.list(:facts)"})
    assert policy.allow_memory_write
    refute policy.allow_network
  end

  test "research and helper modes expose eeva" do
    assert ToolPolicy.allowed_tool_names(ToolPolicy.research()) == ["eeva"]
    assert ToolPolicy.allowed_tool_names(ToolPolicy.local_context_helper()) == ["eeva"]
  end

  test "policy blocks can only select eeva" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      allowed_tools:
      - eeva
      - modify_file
      blocked_tools:
      - git
      allow_network: true
      """)

    assert ToolPolicy.allowed_tool_names(policy) == ["eeva"]
    assert policy.allow_network
    refute ToolPolicy.confirmation_required?(policy)
  end

  test "normal execution never requires confirmation" do
    for policy <- [ToolPolicy.default(), ToolPolicy.research(), ToolPolicy.local_context_helper()] do
      refute ToolPolicy.confirmation_required?(policy)
    end
  end
end
