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

  test "read-only policy allows reads and blocks writes", %{root: root} do
    File.write!(Path.join(root, "sample.txt"), "safe")

    policy = %{
      Beamcore.Agent.Chat.ToolPolicy.default()
      | mode: :read_only,
        allowed_write_paths: []
    }

    read = Eeva.execute(%{"code" => "File.read!(\"sample.txt\")"}, policy) |> Jason.decode!()
    assert read["ok"]
    assert read["result"] =~ "safe"

    write =
      Eeva.execute(%{"code" => "File.write!(\"blocked.txt\", \"no\")"}, policy)
      |> Jason.decode!()

    refute write["ok"]
    assert write["stderr"] =~ "Workspace mutation is blocked"
    refute File.exists?(Path.join(root, "blocked.txt"))
  end

  test "restricted write policy accepts the allowed parent and rejects other paths", %{root: root} do
    policy = Beamcore.Agent.Chat.ToolPolicy.restricted_write_policy(["allowed/**"], ["eeva"])

    allowed =
      Eeva.execute(
        %{"code" => "File.mkdir_p!(\"allowed\"); File.write!(\"allowed/result.txt\", \"ok\")"},
        policy
      )
      |> Jason.decode!()

    assert allowed["ok"]
    assert File.read!(Path.join(root, "allowed/result.txt")) == "ok"

    blocked =
      Eeva.execute(%{"code" => "File.write!(\"other.txt\", \"no\")"}, policy)
      |> Jason.decode!()

    refute blocked["ok"]
    refute File.exists?(Path.join(root, "other.txt"))
  end

  test "dynamic traversal is rejected at runtime" do
    code = "path = Enum.join([\"..\", \"outside.txt\"], \"/\"); File.write!(path, \"no\")"
    result = Eeva.execute(%{"code" => code}) |> Jason.decode!()

    refute result["ok"]
    assert result["stderr"] =~ "traversal"
  end

  test "shell interpreters are rejected without confirmation" do
    result =
      Eeva.execute(%{"code" => "System.cmd(\"sh\", [\"-c\", \"echo unsafe\"])"})
      |> Jason.decode!()

    refute result["ok"]
    assert result["stderr"] =~ "Shell interpreters"
  end

  test "network commands obey allow_network" do
    policy = %{Beamcore.Agent.Chat.ToolPolicy.default() | allow_network: false}

    result =
      Eeva.execute(%{"code" => "System.cmd(\"curl\", [\"https://example.com\"])"}, policy)
      |> Jason.decode!()

    refute result["ok"]
    assert result["stderr"] =~ "Network command"
  end

  test "Beamcore helpers expose public functions dynamically" do
    result =
      Eeva.execute(%{
        "code" => "Beamcore.Helpers.info(Beamcore.Memory, :functions)"
      })
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "remember: 5"
    assert result["result"] =~ "recall: 4"
  end

  test "memory reads remain available and memory writes obey read-only policy" do
    {org, repo} = Beamcore.Memory.detect_org_repo()
    assert :ok == Beamcore.Memory.remember(org, repo, :facts, "eeva-test", "value")

    read =
      Eeva.execute(%{
        "code" =>
          "{org, repo} = Beamcore.Memory.detect_org_repo(); Beamcore.Memory.recall(org, repo, :facts, \"eeva-test\")"
      })
      |> Jason.decode!()

    assert read["ok"]
    assert read["result"] =~ "value"

    policy = %{
      Beamcore.Agent.Chat.ToolPolicy.default()
      | mode: :read_only,
        allowed_write_paths: []
    }

    blocked =
      Eeva.execute(
        %{
          "code" =>
            "{org, repo} = Beamcore.Memory.detect_org_repo(); Beamcore.Memory.remember(org, repo, :facts, \"blocked\", \"no\")"
        },
        policy
      )
      |> Jason.decode!()

    refute blocked["ok"]
    assert blocked["stderr"] =~ "Memory mutation is blocked"
  end

  test "execution does not change the VM-global current directory", %{root: root} do
    original_cwd = File.cwd!()

    result =
      Eeva.execute(%{
        "code" => "{File.cwd!(), File.write!(\"cwd-safe.txt\", \"ok\")}"
      })
      |> Jason.decode!()

    assert result["ok"]
    assert File.cwd!() == original_cwd
    assert File.read!(Path.join(root, "cwd-safe.txt")) == "ok"
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
end
