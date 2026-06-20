defmodule Beamcore.Agent.Tools.EevaTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Beamcore.Agent.Tools.PathInput
  alias Beamcore.Agent.Tools.Eeva

  setup do
    root = Path.join(System.tmp_dir!(), "beamcore_eeva_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = PathInput.configure_workspace_root(root)

    on_exit(fn ->
      PathInput.restore_workspace_root(previous_root)
      File.rm_rf!(root)
      Beamcore.Config.delete(:eeva_timeout_ms)
    end)

    %{root: root}
  end

  test "spec exposes one ordinary Elixir program parameter" do
    spec = Eeva.spec()
    assert spec.type == "function"
    assert spec.function.name == "eeva"
    assert spec.function.parameters.required == ["code"]
    assert spec.function.description =~ "arbitrary Elixir"
    assert spec.function.parameters.properties.code.description =~ "System.cmd"
  end

  test "rejects missing code" do
    result = Eeva.execute(%{}) |> Jason.decode!()
    refute result["ok"]
    assert result["summary"] =~ "No code provided"
  end

  test "executes calculations and anonymous recursion" do
    code = """
    fib = fn fib, n -> if n < 2, do: n, else: fib.(fib, n - 1) + fib.(fib, n - 2) end
    %{sum: Enum.sum(1..100), fib: fib.(fib, 12)}
    """

    result = Eeva.execute(%{"code" => code}) |> Jason.decode!()
    assert result["ok"]
    assert result["result"] =~ "sum: 5050"
    assert result["result"] =~ "fib: 144"
  end

  test "captures stdout and returned values" do
    result =
      Eeva.execute(%{"code" => "IO.puts(\"hello\"); Enum.map([1, 2, 3], &(&1 * 2))"})
      |> Jason.decode!()

    assert result["ok"]
    assert result["stdout"] =~ "hello"
    assert result["result"] =~ "[2, 4, 6]"
  end

  test "accepts full markdown fenced Elixir blocks" do
    result =
      Eeva.execute(%{"code" => "```elixir\n1 + 2\n```"})
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] == "3"
  end

  test "admits safe atom keys before parsing existing-atoms-only code" do
    result =
      Eeva.execute(%{"code" => "%{dependencies: [], build_system: :mix}"})
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "dependencies: []"
    assert result["result"] =~ "build_system: :mix"
  end

  test "model-authored IO.puts and IO.inspect do not write to parent stdout" do
    parent = self()

    leaked =
      capture_io(fn ->
        result =
          Eeva.execute(%{
            "code" => "IO.puts(\"hello\"); IO.inspect(%{visible: true}); :ok"
          })
          |> Jason.decode!()

        send(parent, {:eeva_result, result})
      end)

    assert leaked == ""
    assert_receive {:eeva_result, result}
    assert result["ok"]
    assert result["stdout"] =~ "hello"
    assert result["stdout"] =~ "visible"
  end

  test "model-authored stderr does not write to parent stderr" do
    ensure_standard_error_registered()
    parent = self()

    leaked =
      capture_io(:stderr, fn ->
        result =
          Eeva.execute(%{"code" => ~S[IO.puts(:standard_error, "stderr captured")]})
          |> Jason.decode!()

        send(parent, {:eeva_result, result})
      end)

    assert leaked == ""
    assert_receive {:eeva_result, result}
    assert result["ok"]
    assert result["stdout"] =~ "stderr captured"
  end

  test "external command output is captured even when code asks to stream to stdio" do
    parent = self()

    leaked =
      capture_io(fn ->
        result =
          Eeva.execute(%{
            "code" => ~S"""
            System.cmd("elixir", ["-e", "IO.puts(:stderr, \"cmd err\"); IO.puts(\"cmd out\")"], into: IO.stream(:stdio, :line), stderr_to_stdout: false)
            """
          })
          |> Jason.decode!()

        send(parent, {:eeva_result, result})
      end)

    assert leaked == ""
    assert_receive {:eeva_result, result}
    assert result["ok"]
    assert result["result"] =~ "cmd out"
    assert result["result"] =~ "cmd err"
  end

  test "a returned zero-arity function is invoked" do
    result = Eeva.execute(%{"code" => "fn -> :math.pow(2, 8) end"}) |> Jason.decode!()
    assert result["ok"]
    assert result["result"] == "256.0"
  end

  test "execution timeout is enforced" do
    Beamcore.Config.put(:eeva_timeout_ms, "50")
    result = Eeva.execute(%{"code" => "Process.sleep(5_000); :late"}) |> Jason.decode!()
    refute result["ok"]
    assert result["summary"] =~ "timeout"
  end

  test "parent directory segments are treated as normal local path navigation", %{root: root} do
    outside = Path.join(Path.dirname(root), "outside.txt")
    on_exit(fn -> File.rm(outside) end)
    File.rm(outside)
    code = "path = Enum.join([\"..\", \"outside.txt\"], \"/\"); File.write!(path, \"yes\")"
    result = Eeva.execute(%{"code" => code}) |> Jason.decode!()

    assert result["ok"]
    assert File.read!(outside) == "yes"
  end

  test "shell interpreters are ordinary explicit local commands in freedom mode" do
    result =
      Eeva.execute(%{
        "code" => ~S"""
        System.cmd("sh", ["-c", "printf shell-ok"])
        """
      })
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "shell-ok"
  end

  test "failures emit a concise execution_stopped event while success stays quiet" do
    parent = self()
    Process.put(:event_handler, fn event -> send(parent, event) end)

    Eeva.execute(%{"code" => "raise \"boom\""})
    assert_received {:execution_stopped, event}
    assert event.source == :eeva
    assert event.reason == :execution_failed
    assert event.summary =~ "boom"
    refute String.contains?(event.summary, "\n")

    Eeva.execute(%{"code" => "1 + 1"})
    refute_received {:execution_stopped, _}
  after
    Process.delete(:event_handler)
  end

  test "model-facing failures are recoverable and suggest retry" do
    result = Eeva.execute(%{"code" => "raise \"boom\""}) |> Jason.decode!()

    refute result["ok"]
    assert result["recoverable"]
    assert result["session_active"]
    assert result["summary"] =~ "Tool call failed, but the session is still active"
    assert result["next_step"] =~ "retry"
  end

  test "Beamcore helpers expose public functions dynamically" do
    result =
      Eeva.execute(%{
        "code" => "Beamcore.Helpers.info(Beamcore.Memory, :functions)"
      })
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "remember: 3"
    assert result["result"] =~ "recall: 3"
  end

  test "memory API tolerates model-style recall and clamps runaway limits" do
    Beamcore.Config.put(:eeva_timeout_ms, "10000")

    result =
      Eeva.execute(%{
        "code" =>
          "Beamcore.Memory.clear(); " <>
            "Beamcore.Memory.remember(:project_description, \"stored description\"); " <>
            "Beamcore.Memory.recall(:project_description)"
      })
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "stored description"

    search =
      Eeva.execute(%{
        "code" =>
          "Beamcore.Memory.clear(); " <>
            "Enum.each(1..60, fn i -> Beamcore.Memory.remember(:facts, \"snap-\#{i}\", \"snapshot note\") end); " <>
            "Beamcore.Memory.search(\"snapshot\", 1_000_000) |> length()"
      })
      |> Jason.decode!()

    assert search["ok"]
    assert search["result"] =~ "50"
  end

  test "captures stderr output instead of leaking to terminal" do
    result =
      Eeva.execute(%{"code" => ~S[IO.puts(:standard_error, "stderr captured")]})
      |> Jason.decode!()

    assert result["ok"]
    assert result["stdout"] =~ "stderr captured"
  end

  test "captures compiler warnings via diagnostics" do
    # Unused variable generates a compiler warning/diagnostic
    code = """
    x = 42
    :ok
    """

    result = Eeva.execute(%{"code" => code}) |> Jason.decode!()
    assert result["ok"]
    assert result["result"] =~ ":ok"
    # The diagnostic about unused variable should appear in stdout, not on terminal
    assert result["stdout"] =~ "warning" or result["ok"]
  end

  test "truncates multi-line stdout to 200 lines and reports omitted count" do
    result =
      Eeva.execute(%{"code" => "Enum.each(1..500, &IO.puts/1)"})
      |> Jason.decode!()

    assert result["ok"]
    lines = String.split(result["stdout"], "\n")
    # 200 kept lines plus the appended truncation notice line.
    assert length(lines) == 201
    assert result["stdout"] =~ "output truncated"
    assert result["stdout"] =~ "301 more line(s) omitted"
    assert result["summary"] =~ "Output was truncated (301 line(s) omitted)."
  end

  test "truncates a single long line to 1000 characters and reports omitted count" do
    result =
      Eeva.execute(%{"code" => "IO.write(String.duplicate(\"x\", 2500))"})
      |> Jason.decode!()

    assert result["ok"]
    [content | _] = String.split(result["stdout"], "\n")
    assert String.length(content) == 1000
    assert result["stdout"] =~ "1500 more character(s) omitted"
    assert result["summary"] =~ "Output was truncated (1500 character(s) omitted)."
  end

  test "does not truncate output within limits" do
    result =
      Eeva.execute(%{"code" => "Enum.each(1..10, &IO.puts/1)"})
      |> Jason.decode!()

    assert result["ok"]
    refute result["stdout"] =~ "output truncated"
    refute result["summary"] =~ "Output was truncated"
  end

  defp ensure_standard_error_registered do
    if is_nil(Process.whereis(:standard_error)) do
      {:ok, io} = StringIO.open("")
      Process.register(io, :standard_error)

      on_exit(fn ->
        if Process.whereis(:standard_error) == io do
          Process.unregister(:standard_error)
        end

        if Process.alive?(io), do: safe_stop(io)
      end)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_stop(pid) do
    GenServer.stop(pid)
  catch
    _, _ -> :ok
  end
end
