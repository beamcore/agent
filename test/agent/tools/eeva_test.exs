defmodule Beamcore.Agent.Tools.EevaTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Eeva

  test "spec/0 returns the expected tool specification" do
    spec = Eeva.spec()
    assert spec.type == "function"
    assert spec.function.name == "eeva"
    assert "code" in spec.function.parameters.required
    assert spec.function.description =~ "1000ms"
  end

  test "execute/1 returns error if no code is provided" do
    result = Eeva.execute(%{})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false
    assert decoded["summary"] =~ "No code provided"
  end

  test "execute/1 returns error for empty/blank code" do
    result = Eeva.execute(%{"code" => "   "})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false
    assert decoded["summary"] =~ "No code provided"
  end

  test "execute/1 executes simple arithmetic code successfully" do
    result = Eeva.execute(%{"code" => "1 + 2"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == true
    assert decoded["exit_code"] == 0
    assert decoded["stdout"] =~ "Returned: 3"
    assert decoded["summary"] == "Elixir code executed successfully."
  end

  test "execute/1 captures standard IO output" do
    result = Eeva.execute(%{"code" => "IO.puts(\"Hello World from Eeva!\")"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == true
    assert decoded["exit_code"] == 0
    assert decoded["stdout"] =~ "Hello World from Eeva!"
  end

  test "execute/1 handles crashing code with diagnostics" do
    result = Eeva.execute(%{"code" => "raise \"Eeva crash test!\""})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false
    assert decoded["exit_code"] == 1

    # Check diagnostics structure
    diag = decoded["diagnostics"]
    assert is_map(diag)
    assert diag["error_type"] == "RuntimeError"
    assert diag["error_message"] == "Eeva crash test!"
    assert diag["hint"] =~ "Runtime error"
    assert diag["stacktrace"] != "(no stacktrace available)"
    assert diag["formatted"] =~ "RuntimeError"
  end

  test "execute/1 provides diagnostics for UndefinedFunctionError" do
    result = Eeva.execute(%{"code" => "NonExistentModule.foo()"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false

    diag = decoded["diagnostics"]
    assert diag["error_type"] == "UndefinedFunctionError"
    assert diag["hint"] =~ "is not defined"
  end

  test "execute/1 provides diagnostics for syntax/compile errors" do
    result = Eeva.execute(%{"code" => "if true do :ok"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false

    diag = decoded["diagnostics"]
    assert diag["error_type"] in ["CompileError", "TokenMissingError", "SyntaxError"]
    assert diag["hint"] =~ ~r/ompilation failed|yntax error/
  end

  test "execute/1 provides diagnostics for ArgumentError" do
    result = Eeva.execute(%{"code" => "String.to_integer(\"not_a_number\")"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false

    diag = decoded["diagnostics"]
    assert diag["error_type"] == "ArgumentError"
    assert diag["hint"] =~ "Bad argument"
  end

  test "execute/1 provides diagnostics for MatchError" do
    result = Eeva.execute(%{"code" => "{:ok, x} = {:error, :boom}"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false

    diag = decoded["diagnostics"]
    assert diag["error_type"] == "MatchError"
    assert diag["hint"] =~ "Pattern match failed"
  end

  test "execute/1 provides diagnostics for KeyError" do
    result = Eeva.execute(%{"code" => "Map.fetch!(%{a: 1}, :b)"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false

    diag = decoded["diagnostics"]
    assert diag["error_type"] == "KeyError"
    assert diag["hint"] =~ "not found"
  end

  test "execute/1 times out after 1 second" do
    result = Eeva.execute(%{"code" => "Process.sleep(5_000)"})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == false
    assert decoded["exit_code"] == 1
    assert decoded["summary"] =~ "timed out"
    assert decoded["summary"] =~ "1000ms"

    diag = decoded["diagnostics"]
    assert diag["error_type"] == "timeout"
    assert diag["hint"] =~ "1000ms"
  end

  test "execute/1 emits eeva_preview via process dict event_handler" do
    test_pid = self()

    Process.put(:event_handler, fn event ->
      send(test_pid, {:preview_event, event})
    end)

    Eeva.execute(%{"code" => "1 + 1"})

    assert_received {:preview_event, {:eeva_preview, "1 + 1"}}
  end

  test "execute/1 emits eeva_preview via $ancestors fallback" do
    test_pid = self()
    {:ok, parent_pid} = Agent.start_link(fn -> %{tui_pid: test_pid} end)

    task =
      Task.async(fn ->
        Process.put(:"$ancestors", [parent_pid])
        Eeva.execute(%{"code" => "IO.puts(\"Hello TUI!\")"})
      end)

    assert_receive {:runtime_event, ^parent_pid, {:eeva_preview, code}}, 3000
    assert code =~ "Hello TUI!"

    result = Task.await(task, 5000)
    decoded = Jason.decode!(result)
    assert decoded["ok"] == true
    assert decoded["stdout"] =~ "Hello TUI!"

    Agent.stop(parent_pid)
  end

  test "execute/1 preserves original code in result" do
    code = "Enum.map([1,2,3], &(&1 * 2))"
    result = Eeva.execute(%{"code" => code})
    decoded = Jason.decode!(result)
    assert decoded["code"] == code
  end

  test "execute/1 captures multiple IO.puts calls" do
    code = """
    IO.puts("line 1")
    IO.puts("line 2")
    IO.puts("line 3")
    :done
    """

    result = Eeva.execute(%{"code" => code})
    decoded = Jason.decode!(result)
    assert decoded["ok"] == true
    assert decoded["stdout"] =~ "line 1"
    assert decoded["stdout"] =~ "line 2"
    assert decoded["stdout"] =~ "line 3"
    assert decoded["stdout"] =~ "Returned: :done"
  end
end
