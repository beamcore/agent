defmodule Beamcore.Agent.Chat.ContextTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.{Context, ToolPolicy}

  test "tracks inspected files from read-like tools without duplicates" do
    context =
      Context.new(:elixir)
      |> Context.update_from_tool("read", %{"filePath" => "README.md"}, "full content is ignored")
      |> Context.update_from_tool("read", %{"filePath" => "README.md"}, "full content is ignored")
      |> Context.update_from_tool("grep", %{"path" => "lib"}, "many matches")

    assert MapSet.to_list(context.inspected_files) |> Enum.sort() == ["README.md", "lib"]
    refute Context.summary(context) =~ "full content is ignored"
  end

  test "tracks modified files from write, edit, fs, and patch tools" do
    patch = """
    --- /dev/null
    +++ b/scratch/a.ex
    @@ -0,0 +1 @@
    +ok
    """

    context =
      Context.new(:elixir)
      |> Context.update_from_tool("write", %{"filePath" => "scratch/a.ex"}, "Successfully wrote")
      |> Context.update_from_tool(
        "edit",
        %{"path" => "scratch/a_test.exs"},
        "Successfully updated"
      )
      |> Context.update_from_tool("fs", %{"operation" => "mkdir", "path" => "scratch"}, "ok")
      |> Context.update_from_tool("patch", %{"patch_content" => patch}, "Patch applied")

    assert "scratch/a.ex" in context.modified_files
    assert "scratch/a_test.exs" in context.modified_files
    assert "scratch" in context.modified_files
  end

  test "records last validation summary from mix validate" do
    result = Jason.encode!(%{"ok" => true, "summary" => "Validation passed."})

    context =
      Context.new(:elixir) |> Context.update_from_tool("mix", %{"command" => "validate"}, result)

    assert context.last_validation == %{
             command: "validate",
             ok: true,
             summary: "Validation passed."
           }

    assert Context.summary(context) =~ "Last validation: mix validate passed"
  end

  test "stores pending action from plan tool without file content" do
    result =
      Beamcore.Agent.Tools.Plan.execute(%{
        "summary" => "Create a scratch module",
        "create_files" => ["scratch/policy_test.ex"],
        "allowed_tools" => ["write", "mix"],
        "validation" => "mix test scratch/policy_test.exs"
      })

    context = Context.new(:elixir) |> Context.update_from_tool("plan", %{}, result)

    assert context.pending_action.summary == "Create a scratch module"
    assert context.pending_action.allowed_write_paths == ["scratch/policy_test.ex"]
    assert context.pending_action.policy.mode == :restricted_write

    assert :ok ==
             ToolPolicy.allow_tool_call(context.pending_action.policy, "write", %{
               "filePath" => "scratch/policy_test.ex"
             })

    assert {:error, message} =
             ToolPolicy.allow_tool_call(context.pending_action.policy, "write", %{
               "filePath" => "scratch/other.ex"
             })

    assert message =~ "scratch/other.ex is not in allowed_write_paths"
    assert Context.summary(context) =~ "Pending action"
    refute Context.summary(context) =~ "defmodule"
  end

  test "records compact blocked attempts" do
    context =
      Context.new(:elixir)
      |> Context.update_from_tool(
        "write",
        %{"filePath" => "eval/a.ex"},
        "Error: Tool call blocked by restricted-write policy: eval/a.ex is not allowed."
      )

    assert ["write eval/a.ex"] == context.blocked_attempts
  end

  test "summary is compact and truncates large lists safely" do
    context =
      Enum.reduce(1..30, Context.new(:elixir), fn i, context ->
        Context.update_from_tool(context, "read", %{"filePath" => "lib/file_#{i}.ex"}, "content")
      end)

    summary = Context.summary(context)

    assert String.length(summary) <= 1_515
    assert summary =~ "Already inspected:"
    assert summary =~ "..."
    refute summary =~ "file content"
  end

  test "current task is set from final complete message, not partial fragments" do
    partial = """
    Policy:
    mode: restricted_write
    allowed_write_paths:
    - scratch/a.ex
    """

    final = partial <> "\nImplement module."

    policy = ToolPolicy.from_user_message(final)
    context = Context.from_user_request(Context.new(:elixir), final, policy)

    assert context.current_task =~ "Implement module"
    assert context.active_constraints |> Enum.any?(&String.contains?(&1, "scratch/a.ex"))
  end
end
