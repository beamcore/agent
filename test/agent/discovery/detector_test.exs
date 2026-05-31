defmodule Beamcore.Agent.Discovery.DetectorTest do
  use ExUnit.Case
  alias Beamcore.Agent.Discovery.Detector

  setup do
    test_dir = "test_discovery_dir"
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  # Language detection tests

  test "detects elixir project when mix.exs exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "mix.exs"))
    assert Detector.detect_language(test_dir) == :elixir
  end

  test "detects erlang project when rebar.config exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "rebar.config"))
    assert Detector.detect_language(test_dir) == :erlang
  end

  test "detects erlang project when erlang.mk exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "erlang.mk"))
    assert Detector.detect_language(test_dir) == :erlang
  end

  test "detects python project when requirements.txt exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "requirements.txt"))
    assert Detector.detect_language(test_dir) == :python
  end

  test "detects python project when setup.py exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "setup.py"))
    assert Detector.detect_language(test_dir) == :python
  end

  test "detects python project when pyproject.toml exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "pyproject.toml"))
    assert Detector.detect_language(test_dir) == :python
  end

  test "detects python project when Pipfile exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "Pipfile"))
    assert Detector.detect_language(test_dir) == :python
  end

  test "detects javascript project when package.json exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    assert Detector.detect_language(test_dir) == :javascript
  end

  test "returns unknown when no language indicators exist", %{test_dir: test_dir} do
    assert Detector.detect_language(test_dir) == :unknown
  end

  # Build system detection tests

  test "detects mix build system when mix.exs exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "mix.exs"))
    assert Detector.detect_build_system(test_dir) == :mix
  end

  test "detects make build system when Makefile exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "Makefile"))
    assert Detector.detect_build_system(test_dir) == :make
  end

  test "detects make build system when makefile exists (lowercase)", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "makefile"))
    assert Detector.detect_build_system(test_dir) == :make
  end

  test "detects make build system when GNUmakefile exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "GNUmakefile"))
    assert Detector.detect_build_system(test_dir) == :make
  end

  test "detects bazel build system when BUILD exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "BUILD"))
    assert Detector.detect_build_system(test_dir) == :bazel
  end

  test "detects bazel build system when WORKSPACE exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "WORKSPACE"))
    assert Detector.detect_build_system(test_dir) == :bazel
  end

  test "detects bazel build system when BUILD.bazel exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "BUILD.bazel"))
    assert Detector.detect_build_system(test_dir) == :bazel
  end

  test "detects poetry build system when pyproject.toml with poetry exists", %{test_dir: test_dir} do
    File.write!(Path.join(test_dir, "pyproject.toml"), "[tool.poetry]\nname = \"test\"")
    assert Detector.detect_build_system(test_dir) == :poetry
  end

  test "detects pip build system when setup.py exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "setup.py"))
    assert Detector.detect_build_system(test_dir) == :pip
  end

  test "detects pip build system when requirements.txt exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "requirements.txt"))
    assert Detector.detect_build_system(test_dir) == :pip
  end

  test "detects npm build system when package.json and package-lock.json exist", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    File.touch!(Path.join(test_dir, "package-lock.json"))
    assert Detector.detect_build_system(test_dir) == :npm
  end

  test "detects yarn build system when yarn.lock exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "yarn.lock"))
    assert Detector.detect_build_system(test_dir) == :yarn
  end

  test "detects pnpm build system when pnpm-lock.yaml exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "pnpm-lock.yaml"))
    assert Detector.detect_build_system(test_dir) == :pnpm
  end

  test "returns unknown build system when no indicators exist", %{test_dir: test_dir} do
    assert Detector.detect_build_system(test_dir) == :unknown
  end

  # Full detection (language + build system) tests

  test "detects elixir with mix build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "mix.exs"))
    assert Detector.detect(test_dir) == {:elixir, :mix}
  end

  test "detects elixir with make build system when both mix.exs and Makefile exist", %{
    test_dir: test_dir
  } do
    File.touch!(Path.join(test_dir, "mix.exs"))
    File.touch!(Path.join(test_dir, "Makefile"))
    # make is checked before mix in build system detection, so it should return :make
    assert Detector.detect(test_dir) == {:elixir, :make}
  end

  test "detects elixir with bazel build system when mix.exs and BUILD exist", %{
    test_dir: test_dir
  } do
    File.touch!(Path.join(test_dir, "mix.exs"))
    File.touch!(Path.join(test_dir, "BUILD"))
    # bazel is checked first, so it should return :bazel
    assert Detector.detect(test_dir) == {:elixir, :bazel}
  end

  test "detects python with poetry build system", %{test_dir: test_dir} do
    File.write!(Path.join(test_dir, "pyproject.toml"), "[tool.poetry]\nname = \"test\"")
    assert Detector.detect(test_dir) == {:python, :poetry}
  end

  test "detects python with pip build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "requirements.txt"))
    assert Detector.detect(test_dir) == {:python, :pip}
  end

  test "detects python with bazel build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "requirements.txt"))
    File.touch!(Path.join(test_dir, "BUILD"))
    assert Detector.detect(test_dir) == {:python, :bazel}
  end

  test "detects javascript with npm build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    File.touch!(Path.join(test_dir, "package-lock.json"))
    assert Detector.detect(test_dir) == {:javascript, :npm}
  end

  test "detects javascript with yarn build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    File.touch!(Path.join(test_dir, "yarn.lock"))
    assert Detector.detect(test_dir) == {:javascript, :yarn}
  end

  test "detects javascript with pnpm build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    File.touch!(Path.join(test_dir, "pnpm-lock.yaml"))
    assert Detector.detect(test_dir) == {:javascript, :pnpm}
  end

  test "detects javascript with make build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    File.touch!(Path.join(test_dir, "Makefile"))
    assert Detector.detect(test_dir) == {:javascript, :make}
  end

  test "detects javascript with bazel build system", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    File.touch!(Path.join(test_dir, "WORKSPACE"))
    assert Detector.detect(test_dir) == {:javascript, :bazel}
  end

  test "returns unknown for both when no indicators exist", %{test_dir: test_dir} do
    assert Detector.detect(test_dir) == {:unknown, :unknown}
  end

  # Priority tests - build system detection order

  test "bazel takes priority over make when both exist", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "BUILD"))
    File.touch!(Path.join(test_dir, "Makefile"))
    assert Detector.detect_build_system(test_dir) == :bazel
  end

  test "make takes priority over mix when both exist", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "Makefile"))
    File.touch!(Path.join(test_dir, "mix.exs"))
    assert Detector.detect_build_system(test_dir) == :make
  end

  test "poetry takes priority over pip when pyproject.toml has poetry", %{test_dir: test_dir} do
    File.write!(Path.join(test_dir, "pyproject.toml"), "[tool.poetry]\nname = \"test\"")
    File.touch!(Path.join(test_dir, "requirements.txt"))
    assert Detector.detect_build_system(test_dir) == :poetry
  end

  test "yarn takes priority over npm when both lock files exist", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "package.json"))
    File.touch!(Path.join(test_dir, "yarn.lock"))
    File.touch!(Path.join(test_dir, "package-lock.json"))
    # yarn is checked before npm, so it should return :yarn
    assert Detector.detect_build_system(test_dir) == :yarn
  end
end
