defmodule Beamcore.MemoryTest do
  use ExUnit.Case, async: false

  alias Beamcore.Memory
  alias Beamcore.Agent.Tools.Memory, as: MemoryTool

  @test_dets_path "tmp/test_memory.dets"

  setup do
    # Clean up any existing test DETS files
    File.rm_rf!(Path.expand(@test_dets_path))

    # Restart a test Memory instance with a clean file
    Memory.clear()

    on_exit(fn ->
      File.rm_rf!(Path.expand(@test_dets_path))
    end)

    :ok
  end

  test "detects org and repo dynamically" do
    {org, repo} = Memory.detect_org_repo()
    assert is_binary(org)
    assert is_binary(repo)
  end

  test "remembers and recalls a memory scoped correctly" do
    org = "my_org"
    repo = "my_repo"

    assert :ok == Memory.remember(org, repo, :patterns, "idiom_1", "use pattern matching")
    assert "use pattern matching" == Memory.recall(org, repo, :patterns, "idiom_1")

    # Scoped isolation: recall with different org/repo should return nil
    assert nil == Memory.recall("other_org", repo, :patterns, "idiom_1")
    assert nil == Memory.recall(org, "other_repo", :patterns, "idiom_1")
    assert nil == Memory.recall(org, repo, :decisions, "idiom_1")
  end

  test "lists memories under a specific type" do
    org = "list_org"
    repo = "list_repo"

    Memory.remember(org, repo, :decisions, "dec_1", "chose OTP")
    Memory.remember(org, repo, :decisions, "dec_2", "chose DETS")
    Memory.remember(org, repo, :patterns, "pat_1", "idiomatic Elixir")

    decisions = Memory.list(org, repo, :decisions)
    assert length(decisions) == 2
    assert {"dec_1", "chose OTP"} in decisions
    assert {"dec_2", "chose DETS"} in decisions

    patterns = Memory.list(org, repo, :patterns)
    assert length(patterns) == 1
    assert {"pat_1", "idiomatic Elixir"} in patterns
  end

  test "forgets a remembered memory" do
    org = "forget_org"
    repo = "forget_repo"

    Memory.remember(org, repo, :errors, "err_1", "stuck in loop")
    assert "stuck in loop" == Memory.recall(org, repo, :errors, "err_1")

    assert :ok == Memory.forget(org, repo, :errors, "err_1")
    assert nil == Memory.recall(org, repo, :errors, "err_1")
  end

  test "persists data across restarts using DETS" do
    # Start a dynamic memory process with custom DETS path
    custom_dets = "tmp/another_test_memory.dets"
    File.rm_rf!(Path.expand(custom_dets))

    {:ok, pid} =
      GenServer.start_link(Memory,
        dets_path: custom_dets,
        dets_name: :another_test_memory,
        ets_name: :another_test_memory
      )

    org = "persist_org"
    repo = "persist_repo"

    assert :ok == GenServer.call(pid, {:remember, org, repo, :context, "key_a", "value_a"})
    assert "value_a" == GenServer.call(pid, {:recall, org, repo, :context, "key_a"})

    # Stop GenServer (which flushes/closes DETS)
    GenServer.stop(pid)

    # Start a new GenServer loading from the same DETS file
    {:ok, pid2} =
      GenServer.start_link(Memory,
        dets_path: custom_dets,
        dets_name: :another_test_memory,
        ets_name: :another_test_memory
      )

    assert "value_a" == GenServer.call(pid2, {:recall, org, repo, :context, "key_a"})

    GenServer.stop(pid2)
    File.rm_rf!(Path.expand(custom_dets))
  end

  # --- Agent Memory Tool Tests ---

  test "tool name and spec" do
    assert MemoryTool.name() == "memory"
    spec = MemoryTool.spec()
    assert spec.type == "function"
    assert spec.function.name == "memory"
    assert "action" in spec.function.parameters.required
  end

  test "tool executes remember, recall, and list actions" do
    # Clear memory state first
    Memory.clear()

    # Remember action
    rem_res =
      MemoryTool.execute(%{
        "action" => "remember",
        "key" => "convention_1",
        "value" => "use HSL colors",
        "type" => "patterns"
      })

    assert rem_res =~ "Successfully remembered"

    # Recall action
    rec_res =
      MemoryTool.execute(%{
        "action" => "recall",
        "key" => "convention_1",
        "type" => "patterns"
      })

    assert rec_res =~ "use HSL colors"

    # List action
    list_res =
      MemoryTool.execute(%{
        "action" => "list",
        "type" => "patterns"
      })

    assert list_res =~ "convention_1"
    assert list_res =~ "use HSL colors"

    # Forget action
    for_res =
      MemoryTool.execute(%{
        "action" => "forget",
        "key" => "convention_1",
        "type" => "patterns"
      })

    assert for_res =~ "Successfully forgot"

    # Recall forgotten action
    rec_forgot =
      MemoryTool.execute(%{
        "action" => "recall",
        "key" => "convention_1",
        "type" => "patterns"
      })

    assert rec_forgot =~ "No patterns memory found"
  end

  test "tool validates input parameters" do
    assert MemoryTool.execute(%{}) =~ "Error: action is required"

    assert MemoryTool.execute(%{"action" => "invalid"}) =~
             "Error: Invalid action"

    assert MemoryTool.execute(%{"action" => "remember"}) =~
             "Error: key is required"

    assert MemoryTool.execute(%{"action" => "remember", "key" => "a"}) =~
             "Error: value is required"

    assert MemoryTool.execute(%{
             "action" => "remember",
             "key" => "a",
             "value" => "b",
             "type" => "invalid"
           }) =~
             "Error: Invalid type"
  end
end
