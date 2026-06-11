defmodule Beamcore.MemoryTest do
  use ExUnit.Case, async: false

  alias Beamcore.Memory

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


  test "model-friendly memory calls survive mistaken limit arguments" do
    Memory.clear()

    assert :ok == Memory.remember(:project_description, "stored description", 1_000_000)
    assert "stored description" == Memory.recall(:project_description, 1_000_000)
    assert "stored description" == Memory.recall("project_description")
  end

  test "search and overview are capped and discoverable" do
    Memory.clear()

    Enum.each(1..60, fn index ->
      assert :ok == Memory.remember(:facts, "snap-#{index}", "snapshot policy")
    end)

    assert length(Memory.search("snapshot", 1_000_000)) == 50

    overview = Memory.overview()
    assert overview.total == 60
    assert Enum.any?(overview.types, &(&1.type == :facts and &1.count == 60))
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

  test "fallback memory uses isolated configured DETS path when no GenServer is running" do
    fallback_dets = "tmp/fallback_test_memory.dets"
    File.rm_rf!(Path.expand(fallback_dets))
    real_default = Path.expand("~/.beamcore/memory.dets")
    real_default_mtime = file_mtime(real_default)

    with_app_env(:memory_dets_path, fallback_dets, fn ->
      stop_memory!()

      try do
        assert :ok ==
                 Memory.remember(
                   "fallback_org",
                   "fallback_repo",
                   :context,
                   "fallback_key",
                   "fallback value"
                 )

        assert "fallback value" ==
                 Memory.recall("fallback_org", "fallback_repo", :context, "fallback_key")

        assert {"fallback_key", "fallback value"} in Memory.list(
                 "fallback_org",
                 "fallback_repo",
                 :context
               )

        assert File.exists?(Path.expand(fallback_dets))
        assert file_mtime(real_default) == real_default_mtime
      after
        stop_memory!()
        close_fallback_memory_store()
        File.rm_rf!(Path.expand(fallback_dets))
      end
    end)

    restart_memory!()
  end

  defp with_app_env(key, value, fun) when is_function(fun, 0) do
    previous = Application.get_env(:agent, key)
    Application.put_env(:agent, key, value)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:agent, key)
      else
        Application.put_env(:agent, key, previous)
      end
    end
  end

  defp stop_memory! do
    case Process.whereis(Memory) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp restart_memory! do
    case Process.whereis(Memory) do
      nil ->
        case Memory.start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp close_fallback_memory_store do
    if :dets.info(:beamcore_memory_store) != :undefined do
      :dets.close(:beamcore_memory_store)
    end

    if :ets.info(:beamcore_memory_store) != :undefined do
      :ets.delete(:beamcore_memory_store)
    end

    :ok
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime
      {:error, :enoent} -> nil
    end
  end
end
