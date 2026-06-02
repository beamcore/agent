defmodule Beamcore.Agent.Tools.TestToolTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.TestTool

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

  defp decode!(json) do
    Jason.decode!(json)
  end

  test "spec returns correct name and parameters" do
    spec = TestTool.spec()
    assert spec.function.name == "test_tool"
    assert spec.function.parameters.properties.args
    assert spec.function.parameters.properties.workdir
  end

  test "detects mix.exs and runs mix test" do
    temp_dir = "tmp/test_mix_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "mix.exs"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, opts ->
          send(parent, {:called, exe, args, opts})
          {"ok", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir, "args" => "--only focus"}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "mix", ["test", "--only", "focus"], opts}
    assert Keyword.get(opts, :cd) =~ temp_dir
    env = Map.new(opts[:env] || [])
    assert env["MIX_ENV"] == "test"
  end

  test "detects Cargo.toml and runs cargo test" do
    temp_dir = "tmp/test_cargo_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "Cargo.toml"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, _opts ->
          send(parent, {:called, exe, args})
          {"cargo test run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "cargo", ["test"]}
  end

  test "detects go.mod and runs go test" do
    temp_dir = "tmp/test_go_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "go.mod"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, _opts ->
          send(parent, {:called, exe, args})
          {"go test run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir, "args" => "-v"}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "go", ["test", "./...", "-v"]}
  end

  test "detects package.json and runs npm test by default" do
    temp_dir = "tmp/test_node_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "package.json"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, _opts ->
          send(parent, {:called, exe, args})
          {"npm test run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "npm", ["test"]}
  end

  test "detects package.json with yarn.lock and runs yarn test" do
    temp_dir = "tmp/test_yarn_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "package.json"))
    File.touch!(Path.join(temp_dir, "yarn.lock"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, _opts ->
          send(parent, {:called, exe, args})
          {"yarn test run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "yarn", ["test"]}
  end

  test "detects requirements.txt and runs pytest with venv if present" do
    temp_dir = "tmp/test_python_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "requirements.txt"))
    # mock a virtual env
    File.mkdir_p!(Path.join(temp_dir, ".venv/bin"))
    File.touch!(Path.join(temp_dir, ".venv/bin/pytest"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, opts ->
          send(parent, {:called, exe, args, opts})
          {"pytest run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, pytest_exe, [], opts}
    assert String.ends_with?(pytest_exe, ".venv/bin/pytest")
    env = Map.new(opts[:env] || [])
    assert env["VIRTUAL_ENV"]
  end

  test "detects pyproject.toml with poetry and runs poetry run pytest" do
    temp_dir = "tmp/test_poetry_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.write!(Path.join(temp_dir, "pyproject.toml"), "[tool.poetry]\nname = \"test\"")
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, _opts ->
          send(parent, {:called, exe, args})
          {"poetry pytest run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "poetry", ["run", "pytest"]}
  end

  test "detects Gemfile and runs bundle exec ruby test or rails test" do
    temp_dir = "tmp/test_ruby_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "Gemfile"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, _opts ->
          send(parent, {:called, exe, args})
          {"ruby test run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "bundle", ["exec", "ruby", "test"]}
  end

  test "detects Makefile and runs make test" do
    temp_dir = "tmp/test_make_#{System.unique_integer([:positive])}"
    File.mkdir_p!(temp_dir)
    File.touch!(Path.join(temp_dir, "Makefile"))
    on_exit(fn -> File.rm_rf!(temp_dir) end)

    parent = self()

    result =
      with_command_runner(
        fn exe, args, _opts ->
          send(parent, {:called, exe, args})
          {"make test run", 0}
        end,
        fn ->
          TestTool.execute(%{"workdir" => temp_dir}) |> decode!()
        end
      )

    assert result["ok"]
    assert_receive {:called, "make", ["test"]}
  end
end
