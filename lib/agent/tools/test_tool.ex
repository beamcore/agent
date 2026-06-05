defmodule Beamcore.Agent.Tools.TestTool do
  @moduledoc """
  Consolidated test runner. Matches build systems deterministically without AI.
  """

  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.{CommandRunner, PathSafety}

  def name, do: "test_tool"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: "Run the project's tests. Automatically detects the build system and runs tests (e.g. 'mix test', 'pytest', 'make test', 'cargo test', 'npm test').",
        parameters: %{
          type: "object",
          properties: %{
            args: %{
              type: "string",
              description: "Optional arguments to pass to the test runner (e.g., test filter or specific file paths)",
              default: ""
            },
            workdir: %{
              type: "string",
              description: "Workspace-relative workdir (defaults to root)."
            }
          }
        }
      }
    }
  end

  def execute(params) do
    args_str = Map.get(params, "args", "")
    workdir = Map.get(params, "workdir", ".")

    with :ok <- ProjectPolicy.allowed_read_path?(workdir),
         {:ok, safe_workdir} <- PathSafety.resolve(workdir) do
      case detect_test_command(safe_workdir, args_str) do
        {:ok, executable, args, run_opts} ->
          CommandRunner.run(name(), "test", executable, args, [workdir: workdir] ++ run_opts)
          |> CommandRunner.encode()

        {:error, reason} ->
          %{
            "ok" => false,
            "tool" => name(),
            "command" => "test",
            "args" => CommandRunner.split_args(args_str),
            "workdir" => workdir,
            "exit_code" => nil,
            "stdout" => "",
            "stderr" => "",
            "output_tail" => reason,
            "output_tail_lines" => 1,
            "truncated" => false,
            "summary" => "Test detection error: #{reason}"
          }
          |> CommandRunner.encode()
      end
    else
      {:error, reason} ->
        %{
          "ok" => false,
          "tool" => name(),
          "command" => "test",
          "args" => CommandRunner.split_args(args_str),
          "workdir" => workdir,
          "exit_code" => nil,
          "stdout" => "",
          "stderr" => "",
          "output_tail" => reason,
          "output_tail_lines" => 1,
          "truncated" => false,
          "summary" => "Path safety error: #{reason}"
        }
        |> CommandRunner.encode()
    end
  end

  defp detect_test_command(safe_workdir, args_str) do
    extra_args = CommandRunner.split_args(args_str)

    if has_makefile?(safe_workdir) do
      handle_makefile(safe_workdir, extra_args)
    else
      detect_fallback_command(safe_workdir, extra_args)
    end
  end

  defp handle_makefile(safe_workdir, extra_args) do
    case read_makefile_content(safe_workdir) do
      {:ok, content} ->
        if makefile_has_target?(content, "test") do
          {:ok, "make", ["test" | extra_args], []}
        else
          # Detect fallback to suggest actionable improvement for the Makefile
          fallback_suggestion =
            case detect_fallback_command(safe_workdir, []) do
              {:ok, executable, fallback_args, _opts} ->
                cmd_str = Enum.join([executable | fallback_args], " ")
                """
                Please add a 'test' target to your Makefile. For example:

                .PHONY: test
                test:
                \t#{cmd_str}
                """

              {:error, _} ->
                """
                Please add a 'test' target to your Makefile to run your tests.
                """
            end

          {:error,
           "A Makefile was detected in #{safe_workdir}, but it is missing the 'test' target.\n\n#{fallback_suggestion}"}
        end

      {:error, reason} ->
        {:error, "Failed to read Makefile: #{inspect(reason)}"}
    end
  end

  defp read_makefile_content(dir) do
    file =
      ["Makefile", "makefile", "GNUmakefile"]
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.find(&File.exists?/1)

    if file do
      File.read(file)
    else
      {:error, :not_found}
    end
  end

  defp makefile_has_target?(content, target) do
    pattern = ~r/^[[:blank:]]*#{Regex.escape(target)}[[:blank:]]*::?/m
    Regex.match?(pattern, content)
  end

  defp detect_fallback_command(safe_workdir, extra_args) do
    cond do
      # 1. Elixir/Mix
      File.exists?(Path.join(safe_workdir, "mix.exs")) ->
        env = [{"MIX_ENV", "test"}]
        {:ok, "mix", ["test" | extra_args], [env: env]}

      # 2. Rust/Cargo
      File.exists?(Path.join(safe_workdir, "Cargo.toml")) ->
        {:ok, "cargo", ["test" | extra_args], []}

      # 3. Go
      File.exists?(Path.join(safe_workdir, "go.mod")) ->
        {:ok, "go", ["test", "./..."] ++ extra_args, []}

      # 4. Bazel
      has_bazel?(safe_workdir) ->
        {:ok, "bazel", ["test", "//..."] ++ extra_args, []}

      # 5. Node/NPM/Yarn/PNPM
      File.exists?(Path.join(safe_workdir, "package.json")) ->
        cond do
          File.exists?(Path.join(safe_workdir, "pnpm-lock.yaml")) ->
            {:ok, "pnpm", ["test" | extra_args], []}

          File.exists?(Path.join(safe_workdir, "yarn.lock")) ->
            {:ok, "yarn", ["test" | extra_args], []}

          true ->
            {:ok, "npm", ["test" | extra_args], []}
        end

      # 6. Python
      is_python?(safe_workdir) ->
        resolve_python_test(safe_workdir, extra_args)

      # 7. Ruby/Rails
      File.exists?(Path.join(safe_workdir, "Gemfile")) ->
        resolve_ruby_test(safe_workdir, extra_args)

      true ->
        {:error, "No supported build system or test suite detected in #{safe_workdir}."}
    end
  end

  defp has_bazel?(dir) do
    File.exists?(Path.join(dir, "BUILD")) or
      File.exists?(Path.join(dir, "WORKSPACE")) or
      File.exists?(Path.join(dir, "BUILD.bazel"))
  end

  defp is_python?(dir) do
    File.exists?(Path.join(dir, "requirements.txt")) or
      File.exists?(Path.join(dir, "setup.py")) or
      File.exists?(Path.join(dir, "pyproject.toml")) or
      File.exists?(Path.join(dir, "Pipfile"))
  end

  defp has_makefile?(dir) do
    File.exists?(Path.join(dir, "Makefile")) or
      File.exists?(Path.join(dir, "makefile")) or
      File.exists?(Path.join(dir, "GNUmakefile"))
  end

  defp resolve_python_test(safe_workdir, extra_args) do
    # Check for venv
    venv_path =
      cond do
        File.exists?(Path.join(safe_workdir, ".venv")) -> Path.join(safe_workdir, ".venv")
        File.exists?(Path.join(safe_workdir, "venv")) -> Path.join(safe_workdir, "venv")
        true -> nil
      end

    cond do
      venv_path ->
        # Use python from venv to run -m pytest or use pytest executable if it exists
        env = [{"VIRTUAL_ENV", Path.expand(venv_path)}, {"PYTHONPATH", System.get_env("PYTHONPATH") || ""}]
        python_exe = Path.join(venv_path, "bin/python")
        pytest_exe = Path.join(venv_path, "bin/pytest")

        if File.exists?(pytest_exe) do
          {:ok, pytest_exe, extra_args, [env: env]}
        else
          {:ok, python_exe, ["-m", "pytest" | extra_args], [env: env]}
        end

      poetry_project?(safe_workdir) ->
        {:ok, "poetry", ["run", "pytest" | extra_args], []}

      true ->
        {:ok, "pytest", extra_args, []}
    end
  end

  defp poetry_project?(dir) do
    path = Path.join(dir, "pyproject.toml")
    File.exists?(path) and (case File.read(path) do
      {:ok, content} -> String.contains?(content, "poetry")
      _ -> false
    end)
  end

  defp resolve_ruby_test(safe_workdir, extra_args) do
    cond do
      # Rails
      File.exists?(Path.join(safe_workdir, "config/application.rb")) or
        File.exists?(Path.join(safe_workdir, "bin/rails")) ->
        {:ok, "bundle", ["exec", "rails", "test" | extra_args], []}

      # RSpec
      File.exists?(Path.join(safe_workdir, "spec")) ->
        {:ok, "bundle", ["exec", "rspec" | extra_args], []}

      # Default
      true ->
        {:ok, "bundle", ["exec", "ruby", "test" | extra_args], []}
    end
  end
end
