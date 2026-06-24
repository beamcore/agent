defmodule Beamcore.MemoryTest do
  use ExUnit.Case, async: false

  alias Beamcore.Memory

  @test_dets_path "tmp/test_memory.dets"

  defp safe_expand(path) do
    case File.cwd() do
      {:ok, cwd} -> Path.expand(path, cwd)
      {:error, _} -> Path.expand(path, System.user_home!())
    end
  end

  setup do
    # Clean up any existing test DETS files
    File.rm_rf!(safe_expand(@test_dets_path))
    File.rm_rf!(safe_expand("tmp/fallback_test_memory.dets"))

    # Restart a test Memory instance with a clean file
    try do
      Memory.clear()
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      File.rm_rf!(safe_expand(@test_dets_path))
      File.rm_rf!(safe_expand("tmp/fallback_test_memory.dets"))
    end)

    :ok
  end

  test "memory process is supervised by the application" do
    assert is_pid(Process.whereis(Memory))

    children = Supervisor.which_children(Beamcore.Agent.Supervisor)
    assert Enum.any?(children, fn {id, pid, _type, _modules} -> id == Memory and is_pid(pid) end)
  end

  test "remembers and recalls a memory" do
    assert :ok == Memory.remember(:patterns, "idiom_1", "use pattern matching")
    assert "use pattern matching" == Memory.recall(:patterns, "idiom_1")

    # Different type should return nil
    assert nil == Memory.recall(:decisions, "idiom_1")
  end

  test "lists memories under a specific type" do
    Memory.remember(:decisions, "dec_1", "chose OTP")
    Memory.remember(:decisions, "dec_2", "chose DETS")
    Memory.remember(:patterns, "pat_1", "idiomatic Elixir")

    decisions = Memory.list(:decisions)
    assert length(decisions) == 2
    assert {"dec_1", "chose OTP"} in decisions
    assert {"dec_2", "chose DETS"} in decisions

    patterns = Memory.list(:patterns)
    assert length(patterns) == 1
    assert {"pat_1", "idiomatic Elixir"} in patterns
  end

  test "forgets a remembered memory" do
    Memory.remember(:errors, "err_1", "stuck in loop")
    assert "stuck in loop" == Memory.recall(:errors, "err_1")

    assert :ok == Memory.forget(:errors, "err_1")
    assert nil == Memory.recall(:errors, "err_1")
  end

  test "recall with integer limit searches by type" do
    Memory.clear()

    Memory.remember(:facts, "snap-1", "snapshot A")
    Memory.remember(:facts, "snap-2", "snapshot B")

    # recall(type, limit) when limit is integer searches that type
    results = Memory.recall(:facts, 10)
    assert is_list(results) or is_binary(results)
  end

  test "search and overview are capped and discoverable" do
    Memory.clear()

    Enum.each(1..60, fn index ->
      assert :ok == Memory.remember(:facts, "snap-#{index}", "snapshot note")
    end)

    assert length(Memory.search("snapshot", 1_000_000)) == 50

    overview = Memory.overview()
    assert overview.total == 60
    assert Enum.any?(overview.types, &(&1.type == :facts and &1.count == 60))
  end

  test "persists data across restarts using DETS" do
    # Start a dynamic memory process with custom DETS path
    custom_dets = "tmp/another_test_memory.dets"
    File.rm_rf!(safe_expand(custom_dets))

    {:ok, pid} =
      GenServer.start_link(Memory,
        dets_path: custom_dets,
        dets_name: :another_test_memory,
        ets_name: :another_test_memory
      )

    assert :ok == GenServer.call(pid, {:remember, :context, "key_a", "value_a"})
    assert "value_a" == GenServer.call(pid, {:recall, :context, "key_a"})

    # Stop GenServer (which flushes/closes DETS)
    GenServer.stop(pid)

    # Start a new GenServer loading from the same DETS file
    {:ok, pid2} =
      GenServer.start_link(Memory,
        dets_path: custom_dets,
        dets_name: :another_test_memory,
        ets_name: :another_test_memory
      )

    assert "value_a" == GenServer.call(pid2, {:recall, :context, "key_a"})

    GenServer.stop(pid2)
    File.rm_rf!(safe_expand(custom_dets))
  end

  test "fallback memory uses isolated configured DETS path when no GenServer is running" do
    fallback_dets = "tmp/fallback_test_memory.dets"
    File.rm_rf!(safe_expand(fallback_dets))
    real_default = safe_expand("~/.beamcore/memory.dets")
    real_default_mtime = file_mtime(real_default)

    with_app_env(:memory_dets_path, fallback_dets, fn ->
      stop_memory!()

      try do
        assert :ok ==
                 Memory.remember(
                   :context,
                   "fallback_key",
                   "fallback value"
                 )

        assert "fallback value" ==
                 Memory.recall(:context, "fallback_key")

        assert {"fallback_key", "fallback value"} in Memory.list(:context)

        assert File.exists?(safe_expand(fallback_dets))
        assert file_mtime(real_default) == real_default_mtime
      after
        stop_memory!()
        close_fallback_memory_store()
        File.rm_rf!(safe_expand(fallback_dets))
      end
    end)

    restart_memory!()
  end

  defp with_app_env(key, value, fun) when is_function(fun, 0) do
    previous = Application.get_env(:beamcore, key)
    Application.put_env(:beamcore, key, value)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:beamcore, key)
      else
        Application.put_env(:beamcore, key, previous)
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
