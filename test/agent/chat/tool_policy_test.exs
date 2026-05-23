defmodule Beamcore.Agent.Chat.ToolPolicyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy

  test "defaults to unconfirmed mode without mutation tools when no Policy block exists" do
    policy = ToolPolicy.from_user_message("Implement the requested change.")

    assert policy.mode == :unconfirmed
    assert policy.allowed_write_paths == []
    assert "plan" in ToolPolicy.allowed_tool_names(policy)
    refute "write" in ToolPolicy.allowed_tool_names(policy)
    refute "edit" in ToolPolicy.allowed_tool_names(policy)
    refute "patch" in ToolPolicy.allowed_tool_names(policy)
    refute "fs" in ToolPolicy.allowed_tool_names(policy)
    refute "task" in ToolPolicy.allowed_tool_names(policy)
    refute "curl" in ToolPolicy.allowed_tool_names(policy)
  end

  test "natural-language read-only examples do not drive policy without a Policy block" do
    policy =
      ToolPolicy.from_user_message("""
      Discuss this quoted example: "do not modify files".
      Then implement the task normally.
      """)

    assert policy.mode == :unconfirmed
  end

  test "mutation without explicit Policy or confirmed plan is blocked" do
    policy = ToolPolicy.from_user_message("Create scratch/a.ex.")

    for tool <- ~w(write edit patch fs) do
      assert {:error, message} = ToolPolicy.allow_tool_call(policy, tool, %{})
      assert message =~ "Mutation requires a confirmed plan or explicit Policy block."
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
    assert "write" in ToolPolicy.allowed_tool_names(policy)
    refute "task" in ToolPolicy.allowed_tool_names(policy)
    refute "curl" in ToolPolicy.allowed_tool_names(policy)
  end

  test "invalid Policy mode fails closed and does not expose mutation tools" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: admin
      allowed_tools:
      - write
      - edit
      - patch
      - fs
      """)

    assert policy.mode == :invalid_policy

    for tool <- ~w(write edit patch fs) do
      refute tool in ToolPolicy.allowed_tool_names(policy)
    end
  end

  test "invalid Policy mode blocks mutation tool calls with a clear message" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: admin
      allowed_tools:
      - write
      - edit
      - patch
      - fs
      """)

    assert {:error, write_message} =
             ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "scratch/a.ex"})

    assert write_message =~ "invalid policy"
    assert write_message =~ "mutation tools are disabled"

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "edit", %{"path" => "scratch/a.ex"})

    assert {:error, _message} =
             ToolPolicy.allow_tool_call(policy, "patch", %{
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
      - write
      - mix
      blocked_tools:
      - task
      - curl
      """)

    assert policy.mode == :restricted_write

    assert policy.allowed_write_paths == [
             "scratch/rolling_average.ex",
             "scratch/rolling_average_test.exs"
           ]

    assert ToolPolicy.allowed_tool_names(policy) == ["write", "mix"]
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
      - write
      """)

    assert policy.allowed_write_paths == ["README.md", "mix.exs"]
    assert :ok == ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "README.md"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "mix.exs"})
  end

  test "Policy block overrides natural-language task body" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      allowed_tools:
      - write
      - mix

      Task body says "do not modify files" as an example, but the Policy block is authoritative.
      """)

    assert policy.mode == :restricted_write
    assert :ok == ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "scratch/a.ex"})
  end

  test "restricted_write allows only listed paths" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      allowed_tools:
      - write
      - edit
      - patch
      - fs
      """)

    assert :ok == ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "scratch/a.ex"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "edit", %{"path" => "scratch/a.ex"})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "scratch/b.ex"})

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

  test "restricted_write enforces every patch path" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      allowed_tools:
      - patch
      """)

    allowed_patch = """
    --- /dev/null
    +++ b/scratch/a.ex
    @@ -0,0 +1 @@
    +ok
    """

    blocked_patch = """
    --- /dev/null
    +++ b/scratch/b.ex
    @@ -0,0 +1 @@
    +bad
    """

    assert :ok == ToolPolicy.allow_tool_call(policy, "patch", %{"patch_content" => allowed_patch})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "patch", %{"patch_content" => blocked_patch})

    assert message =~ "scratch/b.ex is not in allowed_write_paths"
  end

  test "read_only blocks write even if allowed_tools includes write" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - read
      - write
      """)

    refute "write" in ToolPolicy.allowed_tool_names(policy)

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "scratch/a.ex"})

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

  test "unconfirmed policy does not expose image generation" do
    policy = ToolPolicy.from_user_message("Generate an image for the project.")

    refute "image_generation" in ToolPolicy.allowed_tool_names(policy)

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "image_generation", %{
               "output_path" => "generated/image.png"
             })

    assert message =~ "Mutation requires a confirmed plan or explicit Policy block"
  end

  test "default policy allows git by default" do
    policy = ToolPolicy.default()
    assert "git" in ToolPolicy.allowed_tool_names(policy)
  end

  test "yolo policy allows all tools and unrestricted paths" do
    policy = ToolPolicy.yolo()
    assert policy.mode == :unrestricted
    
    allowed = ToolPolicy.allowed_tool_names(policy)
    assert "write" in allowed
    assert "task" in allowed
    assert "curl" in allowed
    assert "git" in allowed
    assert "image_generation" in allowed

    assert :ok == ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "any/path/here.ex"})
    assert :ok == ToolPolicy.allow_tool_call(policy, "task", %{"command" => "rm -rf /"})
  end
end
