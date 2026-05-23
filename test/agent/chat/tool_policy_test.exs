defmodule Beamcore.Agent.Chat.ToolPolicyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy

  test "detects read-only requests" do
    policy = ToolPolicy.from_user_message("Read-only smoke test. Do not modify files.")

    assert policy.mode == :read_only
    refute policy.allow_task
  end

  test "keeps pure read-only requests read-only" do
    for prompt <- [
          "Do not modify files",
          "Read-only smoke test",
          "Analyze only. Do not create, modify, or delete files.",
          "Review the code without changes"
        ] do
      policy = ToolPolicy.from_user_message(prompt)

      assert policy.mode == :read_only
      assert policy.allowed_write_paths == []

      assert {:error, _message} =
               ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "scratch/a.ex"})
    end
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

  test "detects restricted-write requests and extracts allowed paths" do
    policy =
      ToolPolicy.from_user_message(
        "You may create only these two files: scratch/rolling_average.ex and scratch/rolling_average_test.exs. Do not create any other files."
      )

    assert policy.mode == :restricted_write

    assert policy.allowed_write_paths == [
             "scratch/rolling_average.ex",
             "scratch/rolling_average_test.exs"
           ]
  end

  test "extracts allowed paths from bullets, inline text, colon lists, and code formatting" do
    prompts = [
      """
      Allowed files:
      - `scratch/a.ex`
      - `scratch/a_test.exs`
      """,
      "You may create only scratch/a.ex and scratch/a_test.exs",
      "Allowed files: scratch/a.ex, scratch/a_test.exs",
      "Only these files may be created: `scratch/a.ex`, `scratch/a_test.exs`"
    ]

    for prompt <- prompts do
      policy = ToolPolicy.from_user_message(prompt)
      assert policy.mode == :restricted_write
      assert policy.allowed_write_paths == ["scratch/a.ex", "scratch/a_test.exs"]
    end
  end

  test "detects supported Russian restricted-write phrasing" do
    policy =
      ToolPolicy.from_user_message("можно создать только scratch/a.ex, больше ничего не менять")

    assert policy.mode == :restricted_write
    assert policy.allowed_write_paths == ["scratch/a.ex"]
  end

  test "restricted-write allows only listed write and edit paths" do
    policy =
      ToolPolicy.from_user_message(
        "Allowed files: scratch/rolling_average.ex, scratch/rolling_average_test.exs"
      )

    assert :ok ==
             ToolPolicy.allow_tool_call(policy, "write", %{
               "filePath" => "scratch/rolling_average.ex"
             })

    assert :ok ==
             ToolPolicy.allow_tool_call(policy, "write", %{
               "path" => "scratch/rolling_average_test.exs"
             })

    assert :ok ==
             ToolPolicy.allow_tool_call(policy, "edit", %{"path" => "scratch/rolling_average.ex"})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "eval/string_utils.ex"})

    assert message =~ "restricted-write policy"
    assert message =~ "eval/string_utils.ex is not in allowed_write_paths"

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "write", %{"filePath" => "README.md"})

    assert message =~
             "Allowed write paths: scratch/rolling_average.ex, scratch/rolling_average_test.exs"
  end

  test "restricted-write smoke prompt extracts only the requested scratch files" do
    prompt =
      "Small coding quality smoke test. You may create only these two files: scratch/rolling_average.ex and scratch/rolling_average_test.exs. Do not create or modify any other files. Do not use task, curl, git, grep, tree, edit, patch, or fs. Implement Scratch.RollingAverage.moving_average/2. Add ExUnit tests in scratch/rolling_average_test.exs and make the test file load scratch/rolling_average.ex with Code.require_file/2."

    policy = ToolPolicy.from_user_message(prompt)

    assert policy.mode == :restricted_write

    assert policy.allowed_write_paths == [
             "scratch/rolling_average.ex",
             "scratch/rolling_average_test.exs"
           ]
  end

  test "restricted-write allows only parent mkdir for allowed files" do
    policy = ToolPolicy.from_user_message("Create only: scratch/a.ex")

    assert :ok ==
             ToolPolicy.allow_tool_call(policy, "fs", %{
               "operation" => "mkdir",
               "path" => "scratch"
             })

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "fs", %{"operation" => "mkdir", "path" => "eval"})

    assert message =~ "eval is not in allowed_write_paths"
  end

  test "restricted-write keeps fs remove blocked" do
    policy = ToolPolicy.from_user_message("Create only: scratch/a.ex")

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "fs", %{
               "operation" => "remove",
               "path" => "scratch/a.ex",
               "confirm" => true
             })

    assert message =~ "fs \"remove\" is not allowed"
  end

  test "restricted-write enforces every changed patch path" do
    policy = ToolPolicy.from_user_message("Allowed files: scratch/a.ex, scratch/a_test.exs")

    allowed_patch = """
    --- /dev/null
    +++ b/scratch/a.ex
    @@ -0,0 +1 @@
    +defmodule Scratch.A, do: :ok
    """

    blocked_patch = """
    --- /dev/null
    +++ b/eval/string_utils.ex
    @@ -0,0 +1 @@
    +bad
    """

    assert :ok == ToolPolicy.allow_tool_call(policy, "patch", %{"patch_content" => allowed_patch})

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "patch", %{"patch_content" => blocked_patch})

    assert message =~ "eval/string_utils.ex is not in allowed_write_paths"
  end
end
