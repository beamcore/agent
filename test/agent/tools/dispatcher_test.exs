defmodule Beamcore.Agent.Tools.DispatcherTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Tools.Dispatcher

  test "execute returns error for unknown tool" do
    result = Dispatcher.execute("unknown_tool", %{})
    assert result == "Function not implemented"
  end

  test "tool_specs returns safe planning specifications without mutation tools by default" do
    specs = Dispatcher.tool_specs()
    names = Enum.map(specs, fn spec -> spec.function.name end)

    assert "read" in names
    assert "plan" in names
    refute "mix" in names
    refute "write" in names
    refute "edit" in names
    refute "patch" in names
    refute "fs" in names
    refute "task" in names
    refute "web_get" in names
    refute "image_generation" in names
  end

  test "tool_specs includes task only when policy allows explicit delegation" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      allowed_tools:
      - task
      """)

    names = Dispatcher.tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    assert "task" in names
    refute "web_get" in names
  end

  test "tool_specs includes web_get only when policy allows explicit network access" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      allowed_tools:
      - web_get
      """)

    names = Dispatcher.tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    assert "web_get" in names
    refute "task" in names
  end

  test "conductor_tool_specs applies read-only policy" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      """)

    names = Dispatcher.conductor_tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    assert Enum.sort(names) == Enum.sort(~w(read grep glob tree git mix))
    refute "task" in names
    refute "web_get" in names
    refute "write" in names
    refute "edit" in names
    refute "patch" in names
    refute "fs" in names
  end

  test "tool_specs applies restricted-write policy without task, web_get, tree, or git" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      - scratch/a_test.exs
      """)

    names = Dispatcher.conductor_tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    assert Enum.sort(names) == Enum.sort(~w(read grep glob write edit patch fs mix))
    refute "task" in names
    refute "web_get" in names
    refute "tree" in names
    refute "git" in names
    refute "image_generation" in names
  end

  test "tool_specs includes image generation only when explicitly allowed" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - generated/architecture.png
      allowed_tools:
      - image_generation
      """)

    names = Dispatcher.tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    assert names == ["image_generation"]
  end

  test "execute blocks mutating tools in read-only mode" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      """)

    result = Dispatcher.execute("write", %{"filePath" => "tmp.txt", "content" => "bad"}, policy)

    assert result =~ "read-only policy"
  end

  test "execute blocks mutating tools without explicit Policy or confirmed plan" do
    result = Dispatcher.execute("write", %{"filePath" => "tmp.txt", "content" => "bad"})

    assert result =~ "Mutation requires a confirmed plan or explicit Policy block."
  end

  test "execute allows read tools without confirmation" do
    result = Dispatcher.execute("read", %{"filePath" => "README.md", "limit" => 1})

    refute result =~ "Mutation requires"
    refute result =~ "Tool call blocked"
  end

  test "execute blocks unlisted writes in restricted-write mode" do
    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: restricted_write
      allowed_write_paths:
      - scratch/a.ex
      """)

    result = Dispatcher.execute("write", %{"filePath" => "eval/a.ex", "content" => "bad"}, policy)

    assert result =~ "restricted-write policy"
    assert result =~ "eval/a.ex is not in allowed_write_paths"
  end

  test "plan tool stores a non-mutating pending action payload" do
    result =
      Dispatcher.execute("plan", %{
        "summary" => "Create a scratch module",
        "create_files" => ["scratch/policy_test.ex"],
        "allowed_tools" => ["write", "mix"],
        "validation" => "mix test scratch/policy_test.exs"
      })

    assert {:ok, decoded} = Jason.decode(result)
    assert decoded["ok"]
    assert decoded["pending_action"]["create_files"] == ["scratch/policy_test.ex"]

    assert decoded["pending_action"]["policy"]["allowed_write_paths"] == [
             "scratch/policy_test.ex"
           ]

    assert decoded["summary"] =~ "Confirm with /confirm"
  end

  test "plan tool rejects unsafe planned paths" do
    result =
      Dispatcher.execute("plan", %{
        "summary" => "Unsafe plan",
        "create_files" => ["../outside.ex"],
        "allowed_tools" => ["write"]
      })

    assert {:ok, decoded} = Jason.decode(result)
    refute decoded["ok"]
    assert decoded["summary"] =~ "path traversal is not allowed"
  end
end
