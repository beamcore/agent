defmodule Beamcore.LedgerTest do
  use ExUnit.Case, async: false

  alias Beamcore.Ledger

  @test_log_path "tmp/test_ledger.jsonl"

  setup do
    # Ensure any previous test log file is cleaned up
    File.rm_rf!(Path.expand(@test_log_path))
    File.rm_rf!(Path.expand("tmp/another_test_ledger.jsonl"))

    # Reset any ETS metrics
    Ledger.clear()

    on_exit(fn ->
      File.rm_rf!(Path.expand(@test_log_path))
      File.rm_rf!(Path.expand("tmp/another_test_ledger.jsonl"))
    end)

    :ok
  end

  test "fallback logging writes to isolated LEDGER_LOG_PATH when no GenServer is running" do
    fallback_path = "tmp/fallback_test_ledger.jsonl"
    File.rm_rf!(Path.expand(fallback_path))

    with_env("LEDGER_LOG_PATH", fallback_path, fn ->
      stop_ledger!()

      try do
        assert :ok ==
                 Ledger.log_action(
                   "fallback_org",
                   "fallback_repo",
                   "read",
                   %{"path" => "README.md"},
                   "fallback result",
                   12,
                   3,
                   :ok
                 )

        expanded = Path.expand(fallback_path)
        assert File.exists?(expanded)

        [line] = File.read!(expanded) |> String.split("\n", trim: true)
        assert {:ok, record} = Jason.decode(line)
        assert record["org"] == "fallback_org"
        assert record["repo"] == "fallback_repo"
        assert record["tool"] == "read"
        assert record["args"] == %{"path" => "README.md"}
        assert record["result"] == "fallback result"
        assert record["tokens"] == 3
        assert record["status"] == "ok"
      after
        restart_ledger!()
        File.rm_rf!(Path.expand(fallback_path))
      end
    end)
  end

  test "detects org and repo dynamically" do
    {org, repo} = Ledger.detect_org_repo()
    assert is_binary(org)
    assert is_binary(repo)
    assert org != ""
    assert repo != ""
  end

  test "logs action and updates ETS metrics correctly" do
    # Ensure ledger is started in local supervisor or we start a test instance
    # The application supervisor starts Beamcore.Ledger by default.
    # Let's log an action and assert metrics
    org = "test_org"
    repo = "test_repo"
    tool = "grep"
    args = %{"query" => "hello"}
    result = "1 match found"
    duration = 120
    tokens = 15

    assert :ok == Ledger.log_action(org, repo, tool, args, result, duration, tokens, :ok)

    # Allow time for async cast to process
    Process.sleep(50)

    # Retrieve metrics
    metrics = Ledger.get_metrics()

    assert Map.has_key?(metrics, {org, repo, tool, :actions})
    assert Map.has_key?(metrics, {org, repo, tool, :duration})
    assert Map.has_key?(metrics, {org, repo, tool, :tokens})
    refute Map.has_key?(metrics, {org, repo, tool, :errors})

    assert metrics[{org, repo, tool, :actions}] == 1
    assert metrics[{org, repo, tool, :duration}] == 120
    assert metrics[{org, repo, tool, :tokens}] == 15
  end

  test "tracks error actions separately" do
    org = "test_org"
    repo = "test_repo"
    tool = "edit"
    args = %{"file" => "lib/missing.ex"}
    result = "Error: File not found"
    duration = 45
    tokens = 0

    assert :ok == Ledger.log_action(org, repo, tool, args, result, duration, tokens, :error)

    Process.sleep(50)

    metrics = Ledger.get_metrics()
    assert metrics[{org, repo, tool, :actions}] == 1
    assert metrics[{org, repo, tool, :errors}] == 1
    assert metrics[{org, repo, tool, :duration}] == 45
  end

  test "estimates token counts using result length divided by 4 when tokens is 0" do
    org = "test_org"
    repo = "test_repo"
    tool = "read"
    args = %{}
    # 8 characters -> 2 estimated tokens
    result = "12345678"
    duration = 10

    assert :ok == Ledger.log_action(org, repo, tool, args, result, duration, 0, :ok)

    Process.sleep(50)

    metrics = Ledger.get_metrics()
    assert metrics[{org, repo, tool, :tokens}] == 2
  end

  test "exports metrics in Prometheus-compliant format" do
    org = "prom_org"
    repo = "prom_repo"

    Ledger.log_action(org, repo, "read", %{}, "content", 10, 5, :ok)
    Ledger.log_action(org, repo, "write", %{}, "Error: disk full", 25, 0, :error)

    Process.sleep(50)

    prom = Ledger.export_prometheus()

    assert prom =~ "# HELP agent_actions_total"
    assert prom =~ "# TYPE agent_actions_total counter"
    assert prom =~ ~s(agent_actions_total{org="prom_org",repo="prom_repo",tool="read"} 1)
    assert prom =~ ~s(agent_actions_total{org="prom_org",repo="prom_repo",tool="write"} 1)
    assert prom =~ ~s(agent_errors_total{org="prom_org",repo="prom_repo",tool="write"} 1)
    assert prom =~ ~s(agent_action_duration{org="prom_org",repo="prom_repo",tool="read"} 10)
    assert prom =~ ~s(agent_tokens_total{org="prom_org",repo="prom_repo",tool="read"} 5)
  end

  test "writes actions to structured JSONL file" do
    # Start a test Ledger process with a custom log path
    custom_path = "tmp/another_test_ledger.jsonl"
    {:ok, pid} = GenServer.start_link(Ledger, log_path: custom_path)

    org = "file_org"
    repo = "file_repo"
    tool = "git"
    args = %{"cmd" => "status"}
    result = "On branch main"
    duration = 200

    GenServer.cast(
      pid,
      {:log_action, org, repo, tool, args, result, duration, 0, :ok}
    )

    Process.sleep(50)
    GenServer.stop(pid)

    # Verify file content
    expanded = Path.expand(custom_path)
    assert File.exists?(expanded)

    lines = File.read!(expanded) |> String.split("\n", trim: true)
    assert length(lines) == 1

    {:ok, record} = Jason.decode(List.first(lines))
    assert record["org"] == "file_org"
    assert record["repo"] == "file_repo"
    assert record["tool"] == "git"
    assert record["duration_ms"] == 200
    assert record["status"] == "ok"
    assert record["args"] == %{"cmd" => "status"}
    assert record["result"] == "On branch main"
    assert is_binary(record["timestamp"])
  end

  test "does not truncate extremely long results in file output" do
    custom_path = "tmp/another_test_ledger.jsonl"
    {:ok, pid} = GenServer.start_link(Ledger, log_path: custom_path)

    very_long_result = String.duplicate("A", 2000)

    GenServer.cast(
      pid,
      {:log_action, "org", "repo", "read", %{}, very_long_result, 10, 0, :ok}
    )

    Process.sleep(50)
    GenServer.stop(pid)

    lines = File.read!(Path.expand(custom_path)) |> String.split("\n", trim: true)
    {:ok, record} = Jason.decode(List.first(lines))

    assert record["result"] == very_long_result
  end

  defp stop_ledger! do
    case Process.whereis(Beamcore.Ledger) do
      nil ->
        :ok

      _pid ->
        :ok = Supervisor.terminate_child(Beamcore.Agent.Supervisor, Beamcore.Ledger)
    end
  end

  defp restart_ledger! do
    case Process.whereis(Beamcore.Ledger) do
      nil -> Supervisor.restart_child(Beamcore.Agent.Supervisor, Beamcore.Ledger)
      _pid -> :ok
    end
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if previous do
        System.put_env(name, previous)
      else
        System.delete_env(name)
      end
    end
  end
end
