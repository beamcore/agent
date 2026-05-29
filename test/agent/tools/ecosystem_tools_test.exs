defmodule Beamcore.Agent.Tools.EcosystemToolsTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.{Bazel, Go, Make, Node, Ruby, Rust, Terraform}

  @cases [
    {Node, "node", %{"command" => "test"}, "npm", ["test"]},
    {Go, "go", %{"command" => "test"}, "go", ["test", "./..."]},
    {Rust, "rust", %{"command" => "check"}, "cargo", ["check"]},
    {Terraform, "terraform", %{"command" => "fmt"}, "terraform", ["fmt", "-check"]},
    {Ruby, "ruby", %{"command" => "rspec"}, "bundle", ["exec", "rspec"]},
    {Bazel, "bazel", %{"command" => "build", "target" => "//app:lib"}, "bazel",
     ["build", "//app:lib"]}
  ]

  for {module, name, params, executable, args} <- @cases do
    test "#{name} spec has correct name" do
      spec = unquote(module).spec()
      assert spec.function.name == unquote(name)
    end

    test "#{name} maps allowed command to expected executable and args" do
      parent = self()

      result =
        with_runner(
          unquote(name),
          fn exe, argv, opts ->
            send(parent, {:called, exe, argv, opts})
            {"ok", 0}
          end,
          fn ->
            unquote(module).execute(unquote(Macro.escape(params))) |> decode!()
          end
        )

      assert_receive {:called, unquote(executable), unquote(args), opts}
      assert opts[:cd] == File.cwd!()
      assert opts[:stderr_to_stdout]
      assert result["ok"]
      assert result["command"] == unquote(params["command"])
      assert result["executable"] == unquote(executable)
      assert result["args"] == unquote(args)

      assert result["summary"] ==
               "#{unquote(name)} #{unquote(params["command"])} completed successfully."
    end

    test "#{name} appends custom args as argv, not shell text" do
      parent = self()
      params = Map.put(unquote(Macro.escape(params)), "args", "--verbose --flag=value")

      with_runner(
        unquote(name),
        fn exe, argv, _opts ->
          send(parent, {:called, exe, argv})
          {"ok", 0}
        end,
        fn ->
          unquote(module).execute(params) |> decode!()
        end
      )

      assert_receive {:called, unquote(executable), argv}
      assert Enum.take(argv, length(unquote(args))) == unquote(args)
      assert Enum.take(argv, -2) == ["--verbose", "--flag=value"]
    end

    test "#{name} rejects unknown command" do
      result = unquote(module).execute(%{"command" => "shell"}) |> decode!()
      refute result["ok"]
      assert result["summary"] =~ "Disallowed #{unquote(name)} command 'shell'"
    end

    test "#{name} validates workdir with PathSafety" do
      result =
        unquote(module).execute(Map.put(unquote(Macro.escape(params)), "workdir", "../outside"))
        |> decode!()

      refute result["ok"]
      assert result["summary"] =~ "path traversal is not allowed"
    end

    test "#{name} represents failure exit code" do
      result =
        with_runner(
          unquote(name),
          fn _exe, _argv, _opts ->
            {"failure details", 2}
          end,
          fn ->
            unquote(module).execute(unquote(Macro.escape(params))) |> decode!()
          end
        )

      refute result["ok"]
      assert result["exit_code"] == 2
      assert result["output_tail"] == "failure details"
    end

    test "#{name} truncates large output tail" do
      output = Enum.map_join(1..45, "\n", &"line #{&1}")

      result =
        with_runner(
          unquote(name),
          fn _exe, _argv, _opts ->
            {output, 0}
          end,
          fn ->
            unquote(module).execute(unquote(Macro.escape(params))) |> decode!()
          end
        )

      assert result["ok"]
      assert result["truncated"]
      assert result["output_tail_lines"] == 40
      assert result["output_tail"] =~ "line 6"
      assert result["output_tail"] =~ "line 45"
    end
  end

  test "node format prefers format:check when present" do
    tmp = Path.join(System.tmp_dir!(), "agent_node_format_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "package.json"), ~s({"scripts":{"format:check":"prettier -c ."}}))

    parent = self()

    try do
      result =
        File.cd!(tmp, fn ->
          with_runner(
            "node",
            fn exe, argv, _opts ->
              send(parent, {:node, exe, argv})
              {"ok", 0}
            end,
            fn ->
              Node.execute(%{"command" => "format"}) |> decode!()
            end
          )
        end)

      assert result["ok"]
      assert_receive {:node, "npm", ["run", "format:check"]}
    after
      File.rm_rf!(tmp)
    end
  end

  test "node install is marked network and mutating" do
    result =
      with_runner(
        "node",
        fn "npm", ["install"], _opts -> {"ok", 0} end,
        fn -> Node.execute(%{"command" => "install"}) |> decode!() end
      )

    assert result["ok"]
    assert result["classification"] == ["network", "mutating"]
  end

  test "make list reads targets without running make" do
    tmp = Path.join(System.tmp_dir!(), "agent_make_list_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    File.write!(
      Path.join(tmp, "Makefile"),
      """
      # ignored:
      FOO := bar
      .PHONY: test build lint
      test:
      build: deps
      lint format:
      %.o: %.c
      .SILENT:
      """
    )

    try do
      result = File.cd!(tmp, fn -> Make.execute(%{"command" => "list"}) |> decode!() end)

      assert result["ok"]
      assert result["makefile"] == "Makefile"
      assert result["targets"] == ["build", "format", "lint", "test"]
      assert result["stdout"] == "build\nformat\nlint\ntest"
    after
      File.rm_rf!(tmp)
    end
  end

  test "make spec exposes dynamic list/run shape without arbitrary args" do
    spec = Make.spec()

    assert spec.function.name == "make"
    assert spec.function.parameters.properties.command.enum == ["list", "run"]
    assert Map.has_key?(spec.function.parameters.properties, :target)
    refute Map.has_key?(spec.function.parameters.properties, :args)
  end

  test "make list reads GNUmakefile" do
    tmp = Path.join(System.tmp_dir!(), "agent_make_gnu_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "GNUmakefile"), "gnu-target:\n\ttrue\n")

    try do
      result = File.cd!(tmp, fn -> Make.execute(%{"command" => "list"}) |> decode!() end)

      assert result["ok"]
      assert result["makefile"] == "GNUmakefile"
      assert result["targets"] == ["gnu-target"]
    after
      File.rm_rf!(tmp)
    end
  end

  test "make run executes only discovered target through fake runner" do
    tmp = Path.join(System.tmp_dir!(), "agent_make_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "Makefile"), ".PHONY: test\ntest:\n\tmix test\n")
    parent = self()

    try do
      result =
        File.cd!(tmp, fn ->
          with_runner(
            "make",
            fn exe, argv, opts ->
              send(parent, {:make, exe, argv, opts})
              {"ok", 0}
            end,
            fn ->
              Make.execute(%{"command" => "run", "target" => "test"}) |> decode!()
            end
          )
        end)

      assert_receive {:make, "make", ["test"], opts}
      assert Path.basename(opts[:cd]) == Path.basename(tmp)
      assert File.exists?(Path.join(opts[:cd], "Makefile"))
      assert result["ok"]
      assert result["args"] == ["test"]
    after
      File.rm_rf!(tmp)
    end
  end

  test "make run rejects unknown target before execution" do
    tmp = Path.join(System.tmp_dir!(), "agent_make_unknown_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "Makefile"), "test:\n\tmix test\n")

    try do
      result =
        File.cd!(tmp, fn ->
          with_runner(
            "make",
            fn _exe, _argv, _opts -> flunk("make should not run unknown targets") end,
            fn ->
              Make.execute(%{"command" => "run", "target" => "deploy"}) |> decode!()
            end
          )
        end)

      refute result["ok"]
      assert result["summary"] == "Unknown make target: deploy"
    after
      File.rm_rf!(tmp)
    end
  end

  test "make run rejects suspicious target names before execution" do
    tmp = Path.join(System.tmp_dir!(), "agent_make_unsafe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "Makefile"), "test:\n\tmix test\n")

    try do
      result =
        File.cd!(tmp, fn ->
          with_runner(
            "make",
            fn _exe, _argv, _opts -> flunk("make should not run unsafe targets") end,
            fn ->
              Make.execute(%{"command" => "run", "target" => "test;rm"}) |> decode!()
            end
          )
        end)

      refute result["ok"]
      assert result["summary"] == "Unsafe make target: test;rm"
    after
      File.rm_rf!(tmp)
    end
  end

  test "make validates workdir with PathSafety" do
    result =
      Make.execute(%{"command" => "run", "target" => "test", "workdir" => "../outside"})
      |> decode!()

    refute result["ok"]
    assert result["summary"] =~ "path traversal is not allowed"
  end

  test "make parser deduplicates and sorts safe targets" do
    content = """
    # test:
    FOO := bar
    .PHONY: test build lint
    test:
    build: deps
    lint format:
    build test:
    %.o: %.c
    .PHONY:
    .SILENT:
    """

    assert Make.discover_targets(content) == ["build", "format", "lint", "test"]
  end

  test "ruby test uses rails test inside a Rails project" do
    tmp = Path.join(System.tmp_dir!(), "agent_rails_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "config"))
    File.write!(Path.join(tmp, "config/application.rb"), "# rails app")
    parent = self()

    try do
      File.cd!(tmp, fn ->
        with_runner(
          "ruby",
          fn exe, argv, _opts ->
            send(parent, {:ruby, exe, argv})
            {"ok", 0}
          end,
          fn ->
            Ruby.execute(%{"command" => "test"}) |> decode!()
          end
        )
      end)

      assert_receive {:ruby, "bundle", ["exec", "rails", "test"]}
    after
      File.rm_rf!(tmp)
    end
  end

  defp decode!(json), do: Jason.decode!(json)

  defp with_runner(tool, runner, fun) do
    key = :"#{tool}_tool_runner"
    previous = Application.get_env(:agent, key)
    Application.put_env(:agent, key, runner)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:agent, key, previous)
      else
        Application.delete_env(:agent, key)
      end
    end
  end
end
