defmodule Beamcore.Agent.Tools.MixTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Mix

  test "executes an allowed mix command and returns structured JSON" do
    parent = self()

    runner = fn "mix", args, opts ->
      send(parent, {:mix_called, args, opts})
      {"compiled", 0}
    end

    result =
      with_runner(runner, fn ->
        Mix.execute(%{"command" => "compile"}) |> decode!()
      end)

    assert_receive {:mix_called, ["compile"], opts}
    # The runner is called with [cd: workdir, stderr_to_stdout: true]
    # MIX_ENV is set via the shell environment, not passed as an option
    assert Keyword.keyword?(opts)
    assert result["ok"] == true
    assert result["command"] == "compile"
    assert result["args"] == ""
    assert result["exit_code"] == 0
    assert result["stdout"] == "compiled"
    assert result["stderr"] == ""
    assert result["output_tail"] == "compiled"
    assert result["output_tail_lines"] == 1
    assert result["truncated"] == false
    assert result["summary"] == "mix compile completed successfully."
  end

  test "rejects an unknown command" do
    result = Mix.execute(%{"command" => "unknown"}) |> decode!()

    assert result["ok"] == false
    assert result["command"] == "unknown"
    assert result["exit_code"] == nil
    assert result["output_tail"] == ""
    assert result["output_tail_lines"] == 0
    assert result["truncated"] == false
    assert result["summary"] =~ "Disallowed command 'unknown'"
  end

  test "rejects dangerous mix commands" do
    for command <- ["run", "eval", "iex", "cmd", "escript"] do
      result = Mix.execute(%{"command" => command}) |> decode!()

      assert result["ok"] == false
      assert result["summary"] =~ "Disallowed command '#{command}'"
    end
  end

  test "validate runs format, compile, and test in order" do
    parent = self()

    runner = fn "mix", args, opts ->
      send(parent, {:mix_called, args, opts})
      {"ok", 0}
    end

    result =
      with_runner(runner, fn ->
        Mix.execute(%{"command" => "validate"}) |> decode!()
      end)

    assert result["ok"] == true
    assert result["command"] == "validate"
    assert result["exit_code"] == 0

    assert result["summary"] ==
             "Validation passed: format, compile and test completed successfully."

    assert result["output_tail"] == ""
    assert result["output_tail_lines"] == 0
    assert result["truncated"] == false

    assert Enum.map(result["steps"], & &1["name"]) == ["format", "compile", "test"]
    assert Enum.all?(result["steps"], & &1["ok"])

    assert_receive {:mix_called, ["format", "--check-formatted"], format_opts}
    assert_receive {:mix_called, ["compile"], compile_opts}
    assert_receive {:mix_called, ["test"], test_opts}

    # The runner is called with [cd: workdir, stderr_to_stdout: true]
    # MIX_ENV is set via the shell environment, not passed as an option
    assert Keyword.keyword?(format_opts)
    assert Keyword.keyword?(compile_opts)
    assert Keyword.keyword?(test_opts)
  end

  test "includes a compact diagnostic tail for long output" do
    output =
      1..45
      |> Enum.map(&"line #{&1}")
      |> Enum.join("\n")

    runner = fn "mix", ["test"], _opts ->
      {output, 0}
    end

    result =
      with_runner(runner, fn ->
        Mix.execute(%{"command" => "test"}) |> decode!()
      end)

    assert result["ok"] == true
    assert result["stdout"] == output
    assert result["truncated"] == true
    assert result["output_tail_lines"] == 40
    assert result["output_tail"] =~ "line 6"
    assert result["output_tail"] =~ "line 45"
    refute result["output_tail"] =~ "line 1\n"
  end

  test "failed commands point the agent to output_tail" do
    runner = fn "mix", ["test"], _opts ->
      {"line 1\nfailure details", 2}
    end

    result =
      with_runner(runner, fn ->
        Mix.execute(%{"command" => "test"}) |> decode!()
      end)

    assert result["ok"] == false
    assert result["exit_code"] == 2
    assert result["output_tail"] == "line 1\nfailure details"

    assert result["summary"] ==
             "mix test failed with exit code 2. See output_tail for the last diagnostic lines."
  end

  test "validate stops at the first failed step" do
    parent = self()

    runner = fn
      "mix", ["format", "--check-formatted"], _opts ->
        send(parent, {:mix_called, "format"})
        {"formatted", 0}

      "mix", ["compile"], _opts ->
        send(parent, {:mix_called, "compile"})
        {"compile failed", 1}

      "mix", ["test"], _opts ->
        send(parent, {:mix_called, "test"})
        {"test should not run", 0}
    end

    result =
      with_runner(runner, fn ->
        Mix.execute(%{"command" => "validate"}) |> decode!()
      end)

    assert result["ok"] == false
    assert result["exit_code"] == 1

    assert result["summary"] ==
             "Validation stopped at step compile with exit code 1. See that step's output_tail for the last diagnostic lines."

    assert Enum.map(result["steps"], & &1["name"]) == ["format", "compile"]

    failed_step = List.last(result["steps"])
    assert failed_step["name"] == "compile"
    assert failed_step["output_tail"] == "compile failed"
    assert failed_step["truncated"] == false

    assert_receive {:mix_called, "format"}
    assert_receive {:mix_called, "compile"}
    refute_receive {:mix_called, "test"}, 50
  end

  test "rejects unsafe workdir path" do
    result = Mix.execute(%{"command" => "compile", "workdir" => "../outside"}) |> decode!()

    assert result["ok"] == false
    assert result["summary"] =~ "Path safety error:"
  end

  test "executes in a custom workdir when valid" do
    parent = self()

    runner = fn "mix", args, opts ->
      send(parent, {:mix_called, args, opts})
      {"compiled", 0}
    end

    result =
      with_runner(runner, fn ->
        Mix.execute(%{"command" => "compile", "workdir" => "lib"}) |> decode!()
      end)

    assert result["ok"] == true
    assert_receive {:mix_called, ["compile"], opts}
    assert String.ends_with?(opts[:cd], "/lib")
  end

  defp decode!(json) do
    Jason.decode!(json)
  end

  defp with_runner(runner, fun) do
    previous = Application.get_env(:agent, :mix_tool_runner)
    Application.put_env(:agent, :mix_tool_runner, runner)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:agent, :mix_tool_runner, previous)
      else
        Application.delete_env(:agent, :mix_tool_runner)
      end
    end
  end
end
