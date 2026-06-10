defmodule Beamcore.Agent.Tools.EevaTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.FilesystemJournal
  alias Beamcore.Agent.PathSafety
  alias Beamcore.Agent.Tools.Eeva

  setup do
    root = Path.join(System.tmp_dir!(), "beamcore_eeva_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = PathSafety.configure_workspace_root(root)

    on_exit(fn ->
      PathSafety.restore_workspace_root(previous_root)
      File.rm_rf!(root)
      System.delete_env("BEAMCORE_EEVA_TIMEOUT_MS")
    end)

    %{root: root}
  end

  test "spec exposes one ordinary Elixir program parameter" do
    spec = Eeva.spec()
    assert spec.type == "function"
    assert spec.function.name == "eeva"
    assert spec.function.parameters.required == ["code"]
    assert spec.function.description =~ "ordinary Elixir"
    assert spec.function.description =~ "System.cmd"
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

  test "ordinary File and Path calls run from the selected workspace", %{root: root} do
    File.write!(Path.join(root, "sample.txt"), "beamcore\n")

    result =
      Eeva.execute(%{
        "code" => "File.read!(\"sample.txt\") <> inspect(Path.wildcard(\"*.txt\") |> Enum.sort())"
      })
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "beamcore"
    assert result["result"] =~ "sample.txt"
  end

  test "ordinary System.cmd is available" do
    result =
      Eeva.execute(%{"code" => "System.cmd(\"git\", [\"--version\"], stderr_to_stdout: true)"})
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "git version"
  end

  test "journals all workspace mutations caused by arbitrary code", %{root: root} do
    context = %{
      session_id: "eeva-session",
      branch_id: "branch-main",
      checkpoint_id: "checkpoint-before-eeva",
      generation_id: "generation-1",
      workspace_root: root
    }

    code = """
    File.mkdir_p!("generated")
    File.write!("generated/a.txt", "one")
    File.write!("generated/b.txt", "two")
    Path.wildcard("generated/*.txt") |> Enum.sort()
    """

    result =
      FilesystemJournal.with_context(context, fn -> Eeva.execute(%{"code" => code}) end)
      |> Jason.decode!()

    assert result["ok"]
    assert File.read!(Path.join(root, "generated/a.txt")) == "one"
    assert result["filesystem_changes"]["changed_path_count"] >= 3
  end

  test "a returned zero-arity function is invoked" do
    result = Eeva.execute(%{"code" => "fn -> :math.pow(2, 8) end"}) |> Jason.decode!()
    assert result["ok"]
    assert result["result"] == "256.0"
  end

  test "execution timeout is enforced" do
    System.put_env("BEAMCORE_EEVA_TIMEOUT_MS", "50")
    result = Eeva.execute(%{"code" => "Process.sleep(5_000); :late"}) |> Jason.decode!()
    refute result["ok"]
    assert result["summary"] =~ "timeout"
  end
end
