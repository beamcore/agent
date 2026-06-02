defmodule Beamcore.Agent.Chat.ToolPolicyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy

  test "defaults to autonomous yolo mode when no Policy block exists" do
    policy = ToolPolicy.from_user_message("Implement the requested change.")

    assert policy.mode == :unrestricted
    assert policy.allowed_write_paths == ["**/*"]
    assert "plan" in ToolPolicy.allowed_tool_names(policy)
    assert "modify_file" in ToolPolicy.allowed_tool_names(policy)
    assert "modify_file" in ToolPolicy.allowed_tool_names(policy)
    assert "modify_file" in ToolPolicy.allowed_tool_names(policy)
    assert "fs" in ToolPolicy.allowed_tool_names(policy)
    assert "task" in ToolPolicy.allowed_tool_names(policy)
    assert "web_get" in ToolPolicy.allowed_tool_names(policy)

    for tool <- ~w(python node make go rust terraform ruby bazel) do
      assert tool in ToolPolicy.allowed_tool_names(policy)
    end
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

    for tool <- ~w(modify_file fs) do
      assert :ok == ToolPolicy.allow_tool_call(policy, tool, %{})
    end
  end

  test "parses Policy mode read_only" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - read
      - mix
      """)

    assert policy.mode == :read_only
    assert ToolPolicy.allowed_tool_names(policy) == ["read", "mix"]
  end

  test "parses Policy mode development" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      """)

    assert policy.mode == :development
    assert "modify_file" in ToolPolicy.allowed_tool_names(policy)
    assert "python" in ToolPolicy.allowed_tool_names(policy)
    assert "node" in ToolPolicy.allowed_tool_names(policy)
    refute "task" in ToolPolicy.allowed_tool_names(policy)
    refute "web_get" in ToolPolicy.allowed_tool_names(policy)
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
      - fs
      """)

    assert policy.mode == :invalid_policy

    for tool <- ~w(modify_file fs) do
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
      - fs
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

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "fs", %{
               "operation" => "mkdir",
               "path" => "scratch"
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
      - mix
      blocked_tools:
      - task
      - web_get
      """)

    assert policy.mode == :restricted_write

    assert policy.allowed_write_paths == [
             "scratch/rolling_average.ex",
             "scratch/rolling_average_test.exs"
           ]

    assert ToolPolicy.allowed_tool_names(policy) == ["modify_file", "mix"]
  end

  test "Policy parser stops before task body sections" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - read

      Task:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      """)

    assert policy.mode == :read_only
    assert policy.allowed_write_paths == []
    assert ToolPolicy.allowed_tool_names(policy) == ["read"]
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
      - mix

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
      - fs
      """)

    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/a.ex"})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "scratch/b.ex"})

    assert message =~ "scratch/b.ex is not in allowed_write_paths"
  end

  test "restricted_write allows parent mkdir only for allowed paths" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      allowed_tools:
      - fs
      """)

    assert :ok ==
             ToolPolicy.allow_tool_call(policy, "fs", %{
               "operation" => "mkdir",
               "path" => "scratch"
             })

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "fs", %{"operation" => "mkdir", "path" => "eval"})

    assert message =~ "eval is not in allowed_write_paths"
  end



  test "read_only blocks write even if allowed_tools includes write" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - read
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
      - read
      - mix
      blocked_tools:
      - mix
      """)

    assert ToolPolicy.allowed_tool_names(policy) == ["read"]
    assert {:error, _message} = ToolPolicy.allow_tool_call(policy, "mix", %{"command" => "test"})
  end

  test "read_only keeps git and mix constrained" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - git
      - mix
      """)

    assert :ok == ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "status"})

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "git", %{"operation" => "commit"})

    assert :ok == ToolPolicy.allow_tool_call(policy, "mix", %{"command" => "validate"})

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "mix", %{"command" => "format"})
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
    assert "web_get" in allowed
    assert "git" in allowed
    assert "image_generation" in allowed

    assert :ok == ToolPolicy.allow_tool_call(policy, "modify_file", %{"path" => "any/path/here.ex"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "task", %{"command" => "rm -rf /"})
  end
end
