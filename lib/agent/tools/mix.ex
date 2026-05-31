defmodule Beamcore.Agent.Tools.Mix do
  @moduledoc """
  Safe, scoped wrapper for mix commands.
  """
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.PathSafety

  @allowed_commands ~w(test compile format deps.get dialyzer hex.info validate)
  @output_tail_lines 40

  @description """
  Run safe, scoped Elixir mix commands such as test, compile, format, dialyzer, deps.get, and validate.
  Automatically manages the MIX_ENV and returns structured JSON output.
  An essential tool for Elixir compilation, testing, formatting, and dependency resolution.
  """

  def name, do: "mix"

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
              description: "The safe mix subcommand to run (e.g. 'test' or 'validate')"
            },
            args: %{
              type: "string",
              description: "Additional arguments as a single string",
              default: ""
            },
            workdir: %{
              type: "string",
              description: "Workspace-relative workdir (defaults to root)."
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
    workdir = Map.get(params, "workdir", ".")

    with :ok <- ProjectPolicy.allowed_read_path?(workdir),
         {:ok, safe_workdir} <- PathSafety.resolve(workdir) do
      cond do
        command == "validate" ->
          validate(safe_workdir) |> encode()

        command in @allowed_commands ->
          command
          |> run(args, safe_workdir)
          |> encode()

        true ->
          disallowed(command, args) |> encode()
      end
    else
      {:error, reason} ->
        %{
          "ok" => false,
          "command" => command,
          "args" => args,
          "exit_code" => nil,
          "stdout" => "",
          "stderr" => "",
          "output_tail" => reason,
          "output_tail_lines" => 1,
          "truncated" => false,
          "summary" => "Path safety error: #{reason}"
        }
        |> encode()
    end
  end

  defp validate(workdir) do
    steps = [
      {"format", "--check-formatted"},
      {"compile", ""},
      {"test", ""}
    ]

    {results, failed_step, skipped_steps} =
      Enum.reduce_while(steps, {[], nil, []}, fn {command, args}, {results, _failed, _skipped} ->
        result = run(command, args, workdir, command)

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

  defp run(command, args, workdir, name \\ nil) do
    extra = String.split(args, " ", trim: true)

    env =
      Map.new()
      |> Map.put("PATH", System.get_env("PATH") || "")
      |> Map.put("LANG", System.get_env("LANG") || "")
      |> Map.put("HOME", System.get_env("HOME") || "")
      |> Map.put("MIX_ENV", mix_env(command))
      # Convert back to keyword list format
      |> Enum.into([])

    {output, exit_code} =
      runner().("mix", [command | extra], cd: workdir, stderr_to_stdout: true, env: env)

    ok = exit_code == 0

    output = truncate(output)
    diagnostic = output_diagnostic(output)

    Map.merge(
      %{
        "ok" => ok,
        "name" => name || command,
        "command" => command,
        "args" => args,
        "exit_code" => exit_code,
        "stdout" => output,
        "stderr" => "",
        "summary" => command_summary(command, args, ok, exit_code)
      },
      diagnostic
    )
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

  defp command_summary(command, args, true, _exit_code) do
    "mix #{format_command(command, args)} completed successfully."
  end

  defp command_summary(command, args, false, exit_code) do
    "mix #{format_command(command, args)} failed with exit code #{exit_code}. See output_tail for the last diagnostic lines."
  end

  defp validate_summary(true, _failed_step, _skipped_steps, _results) do
    "Validation passed: format, compile and test completed successfully."
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
    Application.get_env(:agent, :mix_tool_runner, &System.cmd/3)
  end

  defp mix_env("test"), do: "test"
  defp mix_env(_), do: "dev"

  defp truncate(output, max \\ 10_000) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
