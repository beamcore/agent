defmodule Beamcore.Agent.Discovery.Detector do
  @moduledoc """
  Scans the working directory to detect the project language and build system.
  Returns a tuple of {language, build_system} where:
    - language: :elixir, :erlang, :python, :javascript, or :unknown
    - build_system: :mix, :make, :bazel, :pip, :poetry, :npm, :yarn, :pnpm, :unknown
  """

  @doc """
  Detects the project language and build system.
  Returns {language, build_system} tuple.
  """
  def detect(dir \\ File.cwd!()) do
    language = detect_language(dir)
    build_system = detect_build_system(dir, language)
    {language, build_system}
  end

  @doc """
  Detects only the project language.
  Returns :elixir, :erlang, :python, :javascript, or :unknown.
  """
  def detect_language(dir \\ File.cwd!()) do
    cond do
      python_project?(dir) -> :python
      javascript_project?(dir) -> :javascript
      mix_project?(dir) -> :elixir
      erlang_project?(dir) -> :erlang
      true -> :unknown
    end
  end

  @doc """
  Detects only the build system for a given directory.
  Returns :mix, :make, :bazel, :pip, :poetry, :npm, :yarn, :pnpm, or :unknown.
  """
  def detect_build_system(dir \\ File.cwd!(), _language = nil) do
    cond do
      bazel_project?(dir) -> :bazel
      make_project?(dir) -> :make
      mix_project?(dir) -> :mix
      poetry_project?(dir) -> :poetry
      pip_project?(dir) -> :pip
      pnpm_project?(dir) -> :pnpm
      yarn_project?(dir) -> :yarn
      npm_project?(dir) -> :npm
      true -> :unknown
    end
  end

  # Language detection helpers

  defp python_project?(dir) do
    File.exists?(Path.join(dir, "requirements.txt")) or
      File.exists?(Path.join(dir, "setup.py")) or
      File.exists?(Path.join(dir, "pyproject.toml")) or
      File.exists?(Path.join(dir, "Pipfile"))
  end

  defp javascript_project?(dir) do
    File.exists?(Path.join(dir, "package.json"))
  end

  defp mix_project?(dir) do
    File.exists?(Path.join(dir, "mix.exs"))
  end

  defp erlang_project?(dir) do
    File.exists?(Path.join(dir, "rebar.config")) or
      File.exists?(Path.join(dir, "erlang.mk"))
  end

  # Build system detection helpers

  defp bazel_project?(dir) do
    File.exists?(Path.join(dir, "BUILD")) or
      File.exists?(Path.join(dir, "WORKSPACE")) or
      File.exists?(Path.join(dir, "BUILD.bazel"))
  end

  defp make_project?(dir) do
    File.exists?(Path.join(dir, "Makefile")) or
      File.exists?(Path.join(dir, "makefile")) or
      File.exists?(Path.join(dir, "GNUmakefile"))
  end

  defp poetry_project?(dir) do
    File.exists?(Path.join(dir, "pyproject.toml")) and
      File.read!(Path.join(dir, "pyproject.toml")) =~ "poetry"
  end

  defp pip_project?(dir) do
    File.exists?(Path.join(dir, "setup.py")) or
      File.exists?(Path.join(dir, "requirements.txt")) or
      (File.exists?(Path.join(dir, "pyproject.toml")) and
         not poetry_project?(dir))
  end

  defp npm_project?(dir) do
    File.exists?(Path.join(dir, "package.json")) and
      File.exists?(Path.join(dir, "package-lock.json"))
  end

  defp yarn_project?(dir) do
    File.exists?(Path.join(dir, "yarn.lock"))
  end

  defp pnpm_project?(dir) do
    File.exists?(Path.join(dir, "pnpm-lock.yaml"))
  end
end
