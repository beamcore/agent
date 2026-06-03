defmodule Beamcore.Agent.Tools.CommandRunnerTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.CommandRunner

  test "uses TaskSupervisor when available" do
    supervisor = Process.whereis(Beamcore.Agent.TaskSupervisor)
    assert is_pid(supervisor)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, opts ->
          {:links, links} = Process.info(self(), :links)
          send(parent, {:runner, exe, args, opts, links})
          {"ok", 0}
        end,
        fn ->
          CommandRunner.run("node", "test", "npm", ["test"])
        end
      )

    assert_receive {:runner, "npm", ["test"], opts, links}
    assert supervisor in links
    assert opts[:cd] == File.cwd!()
    assert result["ok"]
    assert result["summary"] == "node test completed successfully."
  end

  test "falls back when TaskSupervisor is unavailable" do
    stop_task_supervisor!()

    parent = self()

    try do
      result =
        with_command_runner(
          fn exe, args, opts ->
            send(parent, {:runner, exe, args, opts})
            {"ok", 0}
          end,
          fn ->
            CommandRunner.run("go", "test", "go", ["test", "./..."])
          end
        )

      assert_receive {:runner, "go", ["test", "./..."], opts}
      assert opts[:cd] == File.cwd!()
      assert result["ok"]
      assert result["summary"] == "go test completed successfully."
    after
      restart_task_supervisor!()
    end
  end

  test "successful command result shape is unchanged" do
    result =
      with_command_runner(fn "npm", ["test"], _opts -> {"line 1\nline 2", 0} end, fn ->
        CommandRunner.run("node", "test", "npm", ["test"], classification: ["network"])
      end)

    assert result["ok"] == true
    assert result["tool"] == "node"
    assert result["command"] == "test"
    assert result["executable"] == "npm"
    assert result["args"] == ["test"]
    assert result["workdir"] == "."
    assert result["exit_code"] == 0
    assert is_integer(result["duration_ms"])
    assert result["stdout"] == "line 1\nline 2"
    assert result["stderr"] == ""
    assert result["summary"] == "node test completed successfully."
    assert result["classification"] == ["network"]
    assert result["output_tail"] == "line 1\nline 2"
    assert result["output_tail_lines"] == 2
    assert result["truncated"] == false
  end

  test "failure exit code result shape is unchanged" do
    result =
      with_command_runner(fn "cargo", ["check"], _opts -> {"failure details", 2} end, fn ->
        CommandRunner.run("rust", "check", "cargo", ["check"])
      end)

    assert result["ok"] == false
    assert result["exit_code"] == 2
    assert result["stdout"] == "failure details"
    assert result["output_tail"] == "failure details"

    assert result["summary"] ==
             "rust check failed with exit code 2. See output_tail for diagnostics."
  end

  test "timeout result shape is unchanged" do
    result =
      with_command_runner(
        fn "npm", ["test"], _opts ->
          Process.sleep(1_000)
          {"late", 0}
        end,
        fn ->
          CommandRunner.run("node", "test", "npm", ["test"], timeout: 10)
        end
      )

    assert result == %{
             "ok" => false,
             "tool" => "node",
             "command" => "test",
             "args" => [],
             "workdir" => ".",
             "exit_code" => nil,
             "stdout" => "",
             "stderr" => "",
             "output_tail" => "",
             "output_tail_lines" => 0,
             "truncated" => false,
             "summary" => "Command timed out after 10ms: npm test"
           }
  end

  test "external command env preserves user env and clears release internals" do
    with_env(
      %{
        "PATH" => "/fake/beamcore/release/erts/bin:/fake/beamcore/release/bin:/usr/bin:/bin",
        "HOME" => "/tmp/home",
        "LANG" => "en_US.UTF-8",
        "RELEASE_ROOT" => "/fake/beamcore/release",
        "RELEASE_NAME" => "agent",
        "RELEASE_VSN" => "0.1.0",
        "RELEASE_COOKIE" => "secret-cookie",
        "RELEASE_NODE" => "agent",
        "RELEASE_DISTRIBUTION" => "sname",
        "RELEASE_SYS_CONFIG" => "/fake/beamcore/release/sys",
        "RELEASE_VM_ARGS" => "/fake/beamcore/release/vm.args",
        "BINDIR" => "/fake/beamcore/release/bin",
        "ROOTDIR" => "/fake/root",
        "ERL_LIBS" => "/fake/beamcore/release/lib"
      },
      fn ->
        env = CommandRunner.external_env([{"MIX_ENV", "test"}])
        env_map = Map.new(env)

        assert env_map["PATH"] == "/usr/bin:/bin"
        assert env_map["HOME"] == "/tmp/home"
        assert env_map["LANG"] == "en_US.UTF-8"
        assert env_map["MIX_ENV"] == "test"

        for key <- CommandRunner.release_env_keys() do
          assert Map.fetch!(env_map, key) == nil
        end
      end
    )
  end

  test "CommandRunner passes sanitized env to fake runners" do
    parent = self()

    with_env(%{"RELEASE_ROOT" => "/fake/release", "BINDIR" => "/fake/release/bin"}, fn ->
      result =
        with_command_runner(
          fn exe, args, opts ->
            send(parent, {:runner, exe, args, opts})
            {"ok", 0}
          end,
          fn ->
            CommandRunner.run("node", "test", "npm", ["test"])
          end
        )

      assert result["ok"]
      assert_receive {:runner, "npm", ["test"], opts}
      env_map = Map.new(opts[:env])
      assert env_map["PATH"]
      assert env_map["HOME"]
      assert env_map["RELEASE_ROOT"] == nil
      assert env_map["BINDIR"] == nil
    end)
  end

  test "CommandRunner does not mutate global release env while sanitizing commands" do
    release_env = %{
      "RELEASE_ROOT" => "/fake/release",
      "BINDIR" => "/fake/release/bin",
      "ROOTDIR" => "/fake/root",
      "ERL_LIBS" => "/fake/release/lib"
    }

    with_env(release_env, fn ->
      result =
        with_command_runner(fn "npm", ["test"], _opts -> {"ok", 0} end, fn ->
          CommandRunner.run("node", "test", "npm", ["test"])
        end)

      assert result["ok"]

      for {key, value} <- release_env do
        assert System.get_env(key) == value
      end
    end)
  end

  test "concurrent CommandRunner calls use sanitized snapshots without global env mutation" do
    parent = self()

    release_env = %{
      "RELEASE_ROOT" => "/fake/release",
      "BINDIR" => "/fake/release/bin",
      "ROOTDIR" => "/fake/root"
    }

    with_env(release_env, fn ->
      with_command_runner(
        fn exe, args, opts ->
          send(parent, {:runner, exe, args, opts[:env]})
          {"ok", 0}
        end,
        fn ->
          tasks =
            for _ <- 1..2 do
              Task.async(fn -> CommandRunner.run("node", "test", "npm", ["test"]) end)
            end

          results = Enum.map(tasks, &Task.await(&1, 5_000))
          assert Enum.all?(results, & &1["ok"])
        end
      )

      for _ <- 1..2 do
        assert_receive {:runner, "npm", ["test"], env}
        env_map = Map.new(env)
        assert env_map["RELEASE_ROOT"] == nil
        assert env_map["BINDIR"] == nil
        assert env_map["ROOTDIR"] == nil
        assert env_map["PATH"]
        assert env_map["HOME"]
      end

      for {key, value} <- release_env do
        assert System.get_env(key) == value
      end
    end)
  end

  defp with_command_runner(runner, fun) do
    previous = Application.get_env(:agent, :command_runner)
    Application.put_env(:agent, :command_runner, runner)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:agent, :command_runner, previous)
      else
        Application.delete_env(:agent, :command_runner)
      end
    end
  end

  defp stop_task_supervisor! do
    case Process.whereis(Beamcore.Agent.TaskSupervisor) do
      nil ->
        :ok

      _pid ->
        :ok = Supervisor.terminate_child(Beamcore.Agent.Supervisor, Beamcore.Agent.TaskSupervisor)
    end
  end

  defp restart_task_supervisor! do
    case Process.whereis(Beamcore.Agent.TaskSupervisor) do
      nil -> Supervisor.restart_child(Beamcore.Agent.Supervisor, Beamcore.Agent.TaskSupervisor)
      _pid -> :ok
    end
  end

  defp with_env(values, fun) do
    previous = Map.new(Map.keys(values), &{&1, System.get_env(&1)})

    Enum.each(values, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
