defmodule Beamcore.Agent.Chat.ToolPolicyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy

  test "defaults to autonomous yolo mode when no Policy block exists" do
    policy = ToolPolicy.from_user_message("Implement the requested change.")

    assert policy.mode == :unrestricted
    assert policy.allowed_write_paths == ["**/*"]
    assert "plan" in ToolPolicy.allowed_tool_names(policy)
    assert "modify_file" in ToolPolicy.allowed_tool_names(policy)
    assert "eeva" in ToolPolicy.allowed_tool_names(policy)
    assert "task" in ToolPolicy.allowed_tool_names(policy)

    assert "test_tool" in ToolPolicy.allowed_tool_names(policy)
  end

  test "natural-language read-only examples do not drive policy without a Policy block" do
    policy =
      ToolPolicy.from_user_message("""
      Discuss this quoted example: "do not modify files".
      Then implement the task normally.
      """)

    assert policy.mode == :unrestricted
  end

  test "default autonomous policy allows mutation tools subject to hard guards" do
    policy = ToolPolicy.from_user_message("Create scratch/a.ex.")

    for tool <- ~w(modify_file image_generation) do
      assert :ok == ToolPolicy.allow_tool_call(policy, tool, %{})
    end
  end

  test "local context helper exposes only bounded read-only tools" do
    policy = ToolPolicy.local_context_helper(ToolPolicy.yolo(project_policy_bypassed?: true))
    names = ToolPolicy.allowed_tool_names(policy)

    assert policy.mode == :local_context_helper
    assert "eeva" in names
    assert "grep" in names
    assert "git" in names
    refute "modify_file" in names
    refute "task" in names
  end

  test "local context helper blocks mutation tools even if requested directly" do
    policy = ToolPolicy.local_context_helper()

    assert {:error, modify_message} =
             ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})

    assert modify_message =~ "local_context_helper"
  end

  test "local context helper allows only read-only git operations" do
    policy = ToolPolicy.local_context_helper()

    assert :ok == ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "status"})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "commit"})

    assert message =~ "read-only policy"
  end

  test "parses Policy mode read_only" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - eeva
      - test_tool
      """)

    assert policy.mode == :read_only
    assert ToolPolicy.allowed_tool_names(policy) == ["eeva", "test_tool"]
  end

  test "parses Policy mode development" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      """)

    assert policy.mode == :development
    assert "modify_file" in ToolPolicy.allowed_tool_names(policy)
    assert "test_tool" in ToolPolicy.allowed_tool_names(policy)
    refute "task" in ToolPolicy.allowed_tool_names(policy)
  end

  test "invalid Policy mode fails closed and does not expose mutation tools" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: admin
      allowed_tools:
      - modify_file
      - modify_file
      - modify_file
      - image_generation
      """)

    assert policy.mode == :invalid_policy

    for tool <- ~w(modify_file image_generation) do
      refute tool in ToolPolicy.allowed_tool_names(policy)
    end
  end

  test "invalid Policy mode blocks mutation tool calls with a clear message" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: admin
      allowed_tools:
      - modify_file
      - modify_file
      - modify_file
      - image_generation
      """)

    assert {:error, write_message} =
             ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})

    assert write_message =~ "invalid policy"
    assert write_message =~ "mutation tools are disabled"

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "modify_file", %{
               "patch_content" => "+++ b/scratch/a.ex"
             })
  end

  test "parses Policy mode restricted_write with allowed paths and tool filters" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/rolling_average.ex
      - scratch/rolling_average_test.exs
      allowed_tools:
      - modify_file
      - test_tool
      blocked_tools:
      - task
      - git
      """)

    assert policy.mode == :restricted_write

    assert policy.allowed_write_paths == [
             "scratch/rolling_average.ex",
             "scratch/rolling_average_test.exs"
           ]

    assert ToolPolicy.allowed_tool_names(policy) == ["modify_file", "test_tool"]
  end

  test "Policy parser stops before task body sections" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - eeva

      Task:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      """)

    assert policy.mode == :read_only
    assert policy.allowed_write_paths == []
    assert ToolPolicy.allowed_tool_names(policy) == ["eeva"]
  end

  test "restricted_write can target root-level project files" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - README.md
      - mix.exs
      allowed_tools:
      - modify_file
      """)

    assert policy.allowed_write_paths == ["README.md", "mix.exs"]
    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "README.md"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "mix.exs"})
  end

  test "Policy block overrides natural-language task body" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      allowed_tools:
      - modify_file
      - test_tool

      Task body says "do not modify files" as an example, but the Policy block is authoritative.
      """)

    assert policy.mode == :restricted_write
    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})
  end

  test "restricted_write allows only listed paths" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      allowed_tools:
      - modify_file
      - modify_file
      - modify_file
      """)

    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/b.ex"})

    assert message =~ "scratch/b.ex is not in allowed_write_paths"
  end

  test "read_only blocks write even if allowed_tools includes write" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - eeva
      - modify_file
      """)

    refute "modify_file" in ToolPolicy.allowed_tool_names(policy)

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})

    assert message =~ "read-only policy"
  end

  test "blocked_tools wins over allowed_tools" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      allowed_tools:
      - eeva
      - test_tool
      blocked_tools:
      - test_tool
      """)

    assert ToolPolicy.allowed_tool_names(policy) == ["eeva"]

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "test_tool", %{"args" => "test"})
  end

  test "read_only keeps git constrained and allows test_tool" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - git
      - test_tool
      """)

    assert :ok == ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "status"})

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "commit"})

    assert :ok == ToolPolicy.allow_tool_call(policy, "test_tool", %{"args" => ""})
  end

  test "restricted_write allows explicitly listed image generation output path" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - generated/architecture.png
      allowed_tools:
      - image_generation
      """)

    assert ToolPolicy.allowed_tool_names(policy) == ["image_generation"]

    assert :ok ==
             ToolPolicy.allow_tool_call(policy, "image_generation", %{
               "output_path" => "generated/architecture.png"
             })

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "image_generation", %{
               "output_path" => "generated/other.png"
             })

    assert message =~ "restricted-write policy"
  end

  test "default autonomous policy exposes image generation subject to path policy" do
    policy = ToolPolicy.from_user_message("Generate an image for the project.")

    assert "image_generation" in ToolPolicy.allowed_tool_names(policy)

    assert :ok =
             ToolPolicy.allow_tool_call(policy, "image_generation", %{
               "output_path" => "generated/image.png"
             })
  end

  test "default policy allows git by default" do
    policy = ToolPolicy.default()
    assert "git" in ToolPolicy.allowed_tool_names(policy)
  end

  test "yolo policy allows all tools and unrestricted paths" do
    policy = ToolPolicy.yolo()
    assert ToolPolicy.default() == policy
    assert policy.mode == :unrestricted

    allowed = ToolPolicy.allowed_tool_names(policy)
    assert "modify_file" in allowed
    assert "task" in allowed
    assert "eeva" in allowed
    assert "git" in allowed
    assert "image_generation" in allowed

    assert :ok ==
             ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "any/path/here.ex"})

    assert :ok == ToolPolicy.allow_tool_call(policy, "task", %{"command" => "rm -rf /"})
  end
end
