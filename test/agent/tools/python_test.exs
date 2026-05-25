defmodule Beamcore.Agent.Tools.PythonTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Python

  test "executes an allowed python command and returns structured JSON" do
    parent = self()

    runner = fn "python3", args, opts ->
      send(parent, {:python_called, args, opts})
      {"compiled", 0}
    end

    result =
      with_runner(runner, fn ->
        Python.execute(%{"command" => "build"}) |> decode!()
      end)

    assert_receive {:python_called, ["build"], _opts}
    assert result["ok"] == true
    assert result["command"] == "build"
    assert result["args"] == ""
    assert result["exit_code"] == 0
    assert result["stdout"] == "compiled"
    assert result["stderr"] == ""
    assert result["output_tail"] == "compiled"
    assert result["output_tail_lines"] == 1
    assert result["truncated"] == false
    assert result["summary"] == "python build completed successfully."
  end

  test "rejects an unknown command" do
    result = Python.execute(%{"command" => "unknown"}) |> decode!()

    assert result["ok"] == false
    assert result["command"] == "unknown"
    assert result["exit_code"] == nil
    assert result["output_tail"] == ""
    assert result["output_tail_lines"] == 0
    assert result["truncated"] == false
    assert result["summary"] =~ "Disallowed command 'unknown'"
  end

  test "rejects dangerous python commands" do
    for command <- ["run", "exec", "shell", "eval", "console"] do
      result = Python.execute(%{"command" => command}) |> decode!()

      assert result["ok"] == false
      assert result["summary"] =~ "Disallowed command '#{command}'"
    end
  end

  test "validate runs format, lint, type-check, and test in order" do
    parent = self()

    runner = fn "python3", args, opts ->
      send(parent, {:python_called, args, opts})
      {"ok", 0}
    end

    result =
      with_runner(runner, fn ->
        Python.execute(%{"command" => "validate"}) |> decode!()
      end)

    assert result["ok"] == true
    assert result["command"] == "validate"
    assert result["exit_code"] == 0

    assert result["summary"] ==
             "Validation passed: format, lint, type-check and test completed successfully."

    assert result["output_tail"] == ""
    assert result["output_tail_lines"] == 0
    assert result["truncated"] == false

    assert Enum.map(result["steps"], & &1["name"]) == ["format", "lint", "type-check", "test"]
    assert Enum.all?(result["steps"], & &1["ok"])

    assert_receive {:python_called, ["format", "--check"], _format_opts}
    assert_receive {:python_called, ["lint"], _lint_opts}
    assert_receive {:python_called, ["type-check"], _type_check_opts}
    assert_receive {:python_called, ["test"], _test_opts}
  end

  test "includes a compact diagnostic tail for long output" do
    output =
      1..45
      |> Enum.map(&"line #{&1}")
      |> Enum.join("\n")

    runner = fn "python3", ["test"], _opts ->
      {output, 0}
    end

    result =
      with_runner(runner, fn ->
        Python.execute(%{"command" => "test"}) |> decode!()
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
    runner = fn "python3", ["test"], _opts ->
      {"line 1\nfailure details", 2}
    end

    result =
      with_runner(runner, fn ->
        Python.execute(%{"command" => "test"}) |> decode!()
      end)

    assert result["ok"] == false
    assert result["exit_code"] == 2
    assert result["output_tail"] == "line 1\nfailure details"

    assert result["summary"] ==
             "python test failed with exit code 2. See output_tail for the last diagnostic lines."
  end

  test "validate stops at the first failed step" do
    parent = self()

    runner = fn
      "python3", ["format", "--check"], _opts ->
        send(parent, {:python_called, "format"})
        {"formatted", 0}

      "python3", ["lint"], _opts ->
        send(parent, {:python_called, "lint"})
        {"lint failed", 1}

      "python3", ["type-check"], _opts ->
        send(parent, {:python_called, "type-check"})
        {"type-check should not run", 0}

      "python3", ["test"], _opts ->
        send(parent, {:python_called, "test"})
        {"test should not run", 0}
    end

    result =
      with_runner(runner, fn ->
        Python.execute(%{"command" => "validate"}) |> decode!()
      end)

    assert result["ok"] == false
    assert result["exit_code"] == 1

    assert result["summary"] ==
             "Validation stopped at step lint with exit code 1. See that step's output_tail for the last diagnostic lines."

    assert Enum.map(result["steps"], & &1["name"]) == ["format", "lint"]

    failed_step = List.last(result["steps"])
    assert failed_step["name"] == "lint"
    assert failed_step["output_tail"] == "lint failed"
    assert failed_step["truncated"] == false

    assert_receive {:python_called, "format"}
    assert_receive {:python_called, "lint"}
    refute_receive {:python_called, "type-check"}, 50
    refute_receive {:python_called, "test"}, 50
  end

  test "passes additional arguments to commands" do
    runner = fn "python3", args, _opts ->
      {"ran with: #{Enum.join(args, " ")}", 0}
    end

    result =
      with_runner(runner, fn ->
        Python.execute(%{"command" => "test", "args" => "--verbose --coverage"}) |> decode!()
      end)

    assert result["ok"] == true
    assert result["command"] == "test"
    assert result["args"] == "--verbose --coverage"
    assert result["stdout"] == "ran with: test --verbose --coverage"
    assert result["summary"] == "python test --verbose --coverage completed successfully."
  end

  test "uses custom python executable from config" do
    parent = self()

    runner = fn "python3.11", args, _opts ->
      send(parent, {:python_called, args})
      {"ok", 0}
    end

    result =
      with_runner(runner, fn ->
        with_python_executable("python3.11", fn ->
          Python.execute(%{"command" => "test"}) |> decode!()
        end)
      end)

    assert result["ok"] == true
    assert_receive {:python_called, ["test"]}
  end

  defp decode!(json) do
    Jason.decode!(json)
  end

  defp with_runner(runner, fun) do
    previous = Application.get_env(:agent, :python_tool_runner)
    Application.put_env(:agent, :python_tool_runner, runner)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:agent, :python_tool_runner, previous)
      else
        Application.delete_env(:agent, :python_tool_runner)
      end
    end
  end

  defp with_python_executable(executable, fun) do
    previous = Application.get_env(:agent, :python_executable)
    Application.put_env(:agent, :python_executable, executable)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:agent, :python_executable, previous)
      else
        Application.delete_env(:agent, :python_executable)
      end
    end
  end
end
