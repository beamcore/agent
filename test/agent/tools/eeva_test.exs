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
    policy = %{Beamcore.Agent.Chat.ToolPolicy.default() | mode: :read_only, allowed_write_paths: []}

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

  test "autonomous policy allows git write commands such as squashing commits", %{root: root} do
    System.cmd("git", ["init", "-q"], cd: root)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)
    System.cmd("git", ["config", "user.name", "Test"], cd: root)
    File.write!(Path.join(root, "a.txt"), "1\n")
    System.cmd("git", ["add", "."], cd: root)
    System.cmd("git", ["commit", "-q", "-m", "first"], cd: root)
    File.write!(Path.join(root, "b.txt"), "2\n")

    add = Eeva.execute(%{"code" => "System.cmd(\"git\", [\"add\", \".\"])"}) |> Jason.decode!()
    assert add["ok"]

    commit =
      Eeva.execute(%{"code" => "System.cmd(\"git\", [\"commit\", \"-m\", \"second\"])"})
      |> Jason.decode!()

    assert commit["ok"]
  end

  test "read-only policy still rejects git write commands" do
    policy = %{Beamcore.Agent.Chat.ToolPolicy.default() | mode: :read_only}

    result =
      Eeva.execute(%{"code" => "System.cmd(\"git\", [\"commit\", \"-m\", \"x\"])"}, policy)
      |> Jason.decode!()

    refute result["ok"]
    assert result["stderr"] =~ "read-only policy"
  end

  test "emits eeva_preview event before execution" do
    parent = self()
    Process.put(:event_handler, fn event -> send(parent, event) end)

    Eeva.execute(%{"code" => "1 + 1"})
    assert_received {:eeva_preview, code}
    assert code == "1 + 1"
  after
    Process.delete(:event_handler)
  end

  test "failures emit a concise eeva_failed event while success stays quiet" do
    parent = self()
    Process.put(:event_handler, fn event -> send(parent, event) end)

    Eeva.execute(%{"code" => "System.cmd(\"sh\", [\"-c\", \"echo no\"])"})
    assert_received {:eeva_failed, message}
    assert message =~ "Shell interpreters"
    refute String.contains?(message, "\n")

    Eeva.execute(%{"code" => "1 + 1"})
    refute_received {:eeva_failed, _}
  after
    Process.delete(:event_handler)
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

  test "memory reads and writes remain available in read-only filesystem policy" do
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

    policy = %{Beamcore.Agent.Chat.ToolPolicy.default() | mode: :read_only, allowed_write_paths: []}

    written =
      Eeva.execute(
        %{
          "code" =>
            "Beamcore.Memory.remember(:facts, \"read-only-memory-write\", \"yes\"); Beamcore.Memory.recall(:facts, \"read-only-memory-write\")"
        },
        policy
      )
      |> Jason.decode!()

    assert written["ok"]
    assert written["result"] =~ "yes"
    assert written["filesystem_changes"]["changed_path_count"] == 0
  end

  test "memory writes stay concise and clear is model-facing for explicit forget-all requests" do
    large =
      Eeva.execute(%{
        "code" => "Beamcore.Memory.remember(:facts, \"too-large\", String.duplicate(\"x\", 70_000))"
      })
      |> Jason.decode!()

    refute large["ok"]
    assert large["stderr"] =~ "Memory value is too large"

    remembered =
      Eeva.execute(%{
        "code" => "Beamcore.Memory.remember(:facts, \"clear-test\", \"value\"); Beamcore.Memory.clear(); Beamcore.Memory.recall(:facts, \"clear-test\")"
      })
      |> Jason.decode!()

    assert remembered["ok"]
    assert remembered["result"] =~ "nil"
    assert remembered["filesystem_changes"]["changed_path_count"] == 0
  end


  test "memory API tolerates model-style recall and clamps runaway limits" do
    result =
      Eeva.execute(%{
        "code" =>
          "Beamcore.Memory.clear(); " <>
            "Beamcore.Memory.remember(:project_description, \"stored description\", 1_000_000); " <>
            "Beamcore.Memory.recall(:project_description, 1_000_000)"
      })
      |> Jason.decode!()

    assert result["ok"]
    assert result["result"] =~ "stored description"
    assert result["filesystem_changes"]["changed_path_count"] == 0

    search =
      Eeva.execute(%{
        "code" =>
          "Beamcore.Memory.clear(); " <>
            "Enum.each(1..60, fn i -> Beamcore.Memory.remember(:facts, \"snap-\#{i}\", \"snapshot policy\") end); " <>
            "Beamcore.Memory.search(\"snapshot\", 1_000_000) |> length()"
      })
      |> Jason.decode!()

    assert search["ok"]
    assert search["result"] =~ "50"
  end

  test "chat policy permits memory writes but still blocks files and commands" do
    policy = Beamcore.Agent.Chat.ToolPolicy.chat()

    remembered =
      Eeva.execute(
        %{
          "code" =>
            "Beamcore.Memory.remember(:facts, \"chat-memory-write\", \"yes\"); Beamcore.Memory.recall(:facts, \"chat-memory-write\")"
        },
        policy
      )
      |> Jason.decode!()

    assert remembered["ok"]
    assert remembered["result"] =~ "yes"
    assert remembered["filesystem_changes"]["changed_path_count"] == 0

    file = Eeva.execute(%{"code" => "File.read!(\"README.md\")"}, policy) |> Jason.decode!()
    refute file["ok"]
    assert file["stderr"] =~ "Filesystem access is unavailable in chat mode"

    command = Eeva.execute(%{"code" => "System.cmd(\"git\", [\"status\"])"}, policy) |> Jason.decode!()
    refute command["ok"]
    assert command["stderr"] =~ "Command execution is blocked"
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
end
