defmodule Beamcore.Agent.Tools.Python do
  @moduledoc """
  Safe, scoped wrapper for Python project management commands.
  Supports virtual environments, dependency management, testing, linting, formatting, and type checking.
  """

  @allowed_commands ~w(test lint format type-check deps install build publish clean validate venv)
  @output_tail_lines 40
  @default_max_truncate 10_000

  @command_mapping %{
    "test" => "pytest",
    "lint" => "ruff check",
    "format" => "black --check",
    "format-fix" => "black",
    "type-check" => "mypy",
    "deps" => "pip list",
    "install" => "pip install",
    "build" => "python -m build",
    "publish" => "twine upload",
    "clean" => "python -m pip cache purge",
    "validate" => "validate",
    "venv" => "venv"
  }

  @description """
  Run safe, scoped Python project management commands.

  Supports:
  - Virtual environment management (create, activate, list)
  - Testing with pytest
  - Linting with ruff
  - Formatting with black
  - Type checking with mypy
  - Dependency management with pip
  - Build and publish with build/twine
  - Validation workflow (format, lint, type-check, test)

  Returns structured JSON output for agent consumption.
  An essential tool for Python project testing, formatting, dependency management, and validation.
  """

  def name, do: "python"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            command: %{
              type: "string",
              enum: @allowed_commands,
              description:
                "The Python project management command to run (e.g. 'test', 'lint', 'venv')"
            },
            args: %{
              type: "string",
              description: "Additional arguments as a single string",
              default: ""
            },
            venv: %{
              type: "string",
              description:
                "Virtual environment name or path to use. If not specified, uses project's default venv or system Python.",
              default: ""
            }
          },
          required: ["command"]
        }
      }
    }
  end

  def execute(params) do
    command = Map.fetch!(params, "command")
    args = Map.get(params, "args", "")
    venv = Map.get(params, "venv", "")

    cond do
      command == "validate" ->
        validate(venv) |> encode()

      command in @allowed_commands ->
        run(command, args, venv) |> encode()

      true ->
        disallowed(command, args) |> encode()
    end
  end

  defp validate(venv) do
    steps = [
      {"format", ""},
      {"lint", ""},
      {"type-check", ""},
      {"test", ""}
    ]

    {results, failed_step, skipped_steps} =
      Enum.reduce_while(steps, {[], nil, []}, fn {command, args}, {results, _failed, _skipped} ->
        result = run(command, args, venv, command)

        if result["ok"] do
          {:cont, {results ++ [result], nil, []}}
        else
          skipped =
            steps
            |> Enum.drop_while(fn {step_command, _} -> step_command != command end)
            |> Enum.drop(1)
            |> Enum.map(fn {step_command, _} -> step_command end)

          {:halt, {results ++ [result], command, skipped}}
        end
      end)

    ok = failed_step == nil

    %{
      "ok" => ok,
      "command" => "validate",
      "args" => "",
      "venv" => venv,
      "exit_code" => if(ok, do: 0, else: 1),
      "stdout" => "",
      "stderr" => "",
      "output_tail" => "",
      "output_tail_lines" => 0,
      "truncated" => false,
      "summary" => validate_summary(ok, failed_step, skipped_steps, results),
      "steps" => results
    }
  end

  defp run(command, args, venv), do: run(command, args, venv, nil)

  defp run(command, args, venv, name) when name == nil, do: run(command, args, venv, command)

  defp run(command, args, venv, name) do
    # Handle virtual environment commands separately
    if command == "venv" do
      run_venv_command(args, venv, name)
    else
      # Resolve the virtual environment path
      venv_path = get_venv_path(venv)

      # Resolve the actual command to run
      actual_command = resolve_command(command, args)

      # Build the full command list using the resolved venv path
      {base_cmd, cmd_args} = build_command(actual_command, venv_path)

      # Set up environment variables using the resolved venv path
      env = build_environment(venv_path)

      # Execute the command
      {output, exit_code} = runner().(base_cmd, cmd_args, stderr_to_stdout: true, env: env)
      ok = exit_code == 0

      output = truncate(output)
      diagnostic = output_diagnostic(output)

      Map.merge(
        %{
          "ok" => ok,
          "name" => name,
          "command" => command,
          "args" => args,
          "venv" => venv,
          "actual_command" => actual_command,
          "exit_code" => exit_code,
          "stdout" => output,
          "stderr" => "",
          "summary" => command_summary(command, args, ok, exit_code, venv)
        },
        diagnostic
      )
    end
  end

  defp run_venv_command(args, venv, name) do
    # Parse venv subcommand
    parts = String.split(args, " ", trim: true)

    subcommand = if parts != [], do: hd(parts), else: "list"
    args_tail = if parts != [], do: tl(parts), else: []
    venv_name = if args_tail != [], do: hd(args_tail), else: venv

    result =
      case subcommand do
        "create" when length(args_tail) >= 1 -> create_venv(hd(args_tail))
        "activate" -> activate_venv(venv_name)
        "list" -> list_venvs()
        "remove" when args_tail != [] -> remove_venv(hd(args_tail))
        _ -> list_venvs()
      end

    result
    |> Map.put("name", name)
    |> Map.put("command", "venv")
    |> Map.put("args", args)
  end

  defp resolve_command(command, args) do
    # Map our command to actual Python tool commands
    case @command_mapping[command] do
      nil ->
        command

      mapped ->
        # If there are args, append them to the mapped command
        if args == "", do: mapped, else: "#{mapped} #{args}"
    end
  end

  defp get_venv_path("") do
    cond do
      File.exists?(".venv") -> ".venv"
      File.exists?("venv") -> "venv"
      true -> nil
    end
  end

  defp get_venv_path(venv) do
    resolve_venv_path(venv) || venv
  end

  defp build_command(command_string, venv_path) do
    parts = String.split(command_string, " ", trim: true)

    if venv_path do
      build_venv_command(parts, venv_path)
    else
      build_system_command(parts)
    end
  end

  defp build_venv_command([first | rest], venv_path) do
    cond do
      first in ["python", "python3"] ->
        {"#{venv_path}/bin/python", rest}

      first == "pip" ->
        pip_path = "#{venv_path}/bin/pip"

        if File.exists?(pip_path) do
          {pip_path, rest}
        else
          {"#{venv_path}/bin/python", ["-m", "pip" | rest]}
        end

      true ->
        tool_path = "#{venv_path}/bin/#{first}"

        if File.exists?(tool_path) do
          {tool_path, rest}
        else
          {"#{venv_path}/bin/python", ["-m", first | rest]}
        end
    end
  end

  defp build_system_command([first | rest]) do
    cond do
      first in ["python", "python3"] ->
        {python_executable(), rest}

      first == "pip" ->
        {python_executable(), ["-m", "pip" | rest]}

      true ->
        {python_executable(), ["-m", first | rest]}
    end
  end

  defp build_environment(venv_path) do
    env = [{"PYTHONPATH", System.get_env("PYTHONPATH") || ""}]

    if venv_path do
      [{"VIRTUAL_ENV", Path.expand(venv_path)} | env]
    else
      env
    end
  end

  defp resolve_venv_path(""), do: nil

  defp resolve_venv_path(venv) do
    if String.starts_with?(venv, "/") || String.starts_with?(venv, "./") do
      if File.exists?(venv), do: venv, else: nil
    else
      locations = [
        venv,
        ".venv",
        "venv",
        "env",
        ".python-venv"
      ]

      Enum.find_value(locations, fn path ->
        expanded = String.replace(path, "~", System.get_env("HOME") || "")
        if File.exists?(expanded), do: expanded, else: nil
      end)
    end
  end

  defp create_venv(venv_name) do
    venv_path = resolve_venv_path(venv_name) || venv_name

    case runner().(python_executable(), ["-m", "venv", venv_path],
           stderr_to_stdout: true,
           env: []
         ) do
      {output, 0} ->
        %{
          "ok" => true,
          "exit_code" => 0,
          "stdout" => output,
          "stderr" => "",
          "summary" => "Virtual environment '#{venv_name}' created at #{venv_path}"
        }

      {output, exit_code} ->
        %{
          "ok" => false,
          "exit_code" => exit_code,
          "stdout" => output,
          "stderr" => "",
          "summary" =>
            "Failed to create virtual environment '#{venv_name}': #{String.trim(output)}"
        }
    end
  end

  defp activate_venv(venv_name) do
    venv_path = resolve_venv_path(venv_name)

    if venv_path && File.exists?(venv_path) do
      %{
        "ok" => true,
        "exit_code" => 0,
        "stdout" => "",
        "stderr" => "",
        "venv_path" => venv_path,
        "summary" => "Virtual environment '#{venv_name}' activated at #{venv_path}"
      }
    else
      %{
        "ok" => false,
        "exit_code" => 1,
        "stdout" => "",
        "stderr" => "",
        "summary" => "Virtual environment '#{venv_name}' not found"
      }
    end
  end

  defp list_venvs do
    # Look for venvs in common locations
    locations = [".venv", "venv", "env", ".python-venv"]

    found =
      locations
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(fn path -> %{"name" => path, "path" => path} end)

    %{
      "ok" => true,
      "exit_code" => 0,
      "stdout" => "",
      "stderr" => "",
      "venvs" => found,
      "summary" => "Found #{length(found)} virtual environment(s)"
    }
  end

  defp remove_venv(venv_name) do
    venv_path = resolve_venv_path(venv_name)

    if venv_path && File.exists?(venv_path) do
      case File.rm_rf(venv_path) do
        {:ok, _} ->
          %{
            "ok" => true,
            "exit_code" => 0,
            "stdout" => "",
            "stderr" => "",
            "summary" => "Virtual environment '#{venv_name}' removed from #{venv_path}"
          }

        {:error, _reason, _details} ->
          %{
            "ok" => false,
            "exit_code" => 1,
            "stdout" => "",
            "stderr" => "",
            "summary" => "Failed to remove virtual environment '#{venv_name}' from #{venv_path}"
          }
      end
    else
      %{
        "ok" => false,
        "exit_code" => 1,
        "stdout" => "",
        "stderr" => "",
        "summary" => "Virtual environment '#{venv_name}' not found"
      }
    end
  end

  defp disallowed(command, args) do
    %{
      "ok" => false,
      "command" => command,
      "args" => args,
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => "",
      "output_tail" => "",
      "output_tail_lines" => 0,
      "truncated" => false,
      "summary" =>
        "Disallowed command '#{command}'. Allowed: #{Enum.join(@allowed_commands, ", ")}"
    }
  end

  defp command_summary(command, args, ok, _exit_code, venv) when ok do
    venv_part = if venv != "", do: " (venv: #{venv})", else: ""
    "python #{format_command(command, args)}#{venv_part} completed successfully."
  end

  defp command_summary(command, args, false, exit_code, venv) do
    venv_part = if venv != "", do: " (venv: #{venv})", else: ""

    "python #{format_command(command, args)}#{venv_part} failed with exit code #{exit_code}. See output_tail for the last diagnostic lines."
  end

  defp validate_summary(true, _failed_step, _skipped_steps, _results) do
    "Validation passed: format, lint, type-check and test completed successfully."
  end

  defp validate_summary(false, failed_step, _skipped_steps, results) do
    exit_code =
      results
      |> Enum.find(%{}, fn result -> result["name"] == failed_step end)
      |> Map.get("exit_code", 1)

    "Validation stopped at step #{failed_step} with exit code #{exit_code}. See that step's output_tail for the last diagnostic lines."
  end

  defp format_command(command, ""), do: command
  defp format_command(command, args), do: "#{command} #{args}"

  defp output_diagnostic(output) do
    lines = output_lines(output)
    tail_lines = Enum.take(lines, -@output_tail_lines)

    %{
      "output_tail" => Enum.join(tail_lines, "\n"),
      "output_tail_lines" => length(tail_lines),
      "truncated" => length(lines) > @output_tail_lines
    }
  end

  defp output_lines(""), do: []
  defp output_lines(output), do: String.split(output, "\n")

  defp encode(result) do
    Jason.encode!(result)
  end

  defp runner do
    Application.get_env(:agent, :python_tool_runner, &System.cmd/3)
  end

  defp python_executable do
    Application.get_env(:agent, :python_executable, "python3")
  end

  defp truncate(output), do: truncate(output, @default_max_truncate)

  defp truncate(output, max) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
