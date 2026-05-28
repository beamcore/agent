defmodule Beamcore.Agent.Tools.Make do
  @moduledoc """
  Allowlisted Make workflow tool.
  """

  alias Beamcore.Agent.Tools.{CommandRunner, PathSafety}

  @allowed_commands ~w(list run)
  @description """
  List Makefile targets or run one explicit target. Make targets are project-defined
  and remain ProjectPolicy-controllable at the tool level.
  """

  def name, do: "make"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", enum: @allowed_commands},
            target: %{type: "string", description: "Required for command=run"},
            args: %{type: "string", description: "Extra argv appended after target"},
            workdir: %{type: "string", description: "Workspace-relative workdir"}
          },
          required: ["command"]
        }
      }
    }
  end

  def execute(%{"command" => "list"} = params), do: list_targets(params) |> CommandRunner.encode()

  def execute(%{"command" => "run"} = params) do
    case target(params) do
      {:ok, target} ->
        CommandRunner.run(
          name(),
          "run",
          "make",
          [target] ++ CommandRunner.split_args(params["args"]),
          workdir: Map.get(params, "workdir", ".")
        )
        |> CommandRunner.encode()

      {:error, reason} ->
        Map.put(CommandRunner.disallowed(name(), "run", @allowed_commands), "summary", reason)
        |> CommandRunner.encode()
    end
  end

  def execute(%{"command" => command}),
    do: CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()

  defp list_targets(params) do
    workdir = Map.get(params, "workdir", ".")

    with {:ok, safe_workdir} <- PathSafety.resolve(workdir),
         {:ok, content} <- read_makefile(safe_workdir) do
      targets =
        content
        |> String.split("\n")
        |> Enum.flat_map(&target_line/1)
        |> Enum.uniq()
        |> Enum.sort()

      %{
        "ok" => true,
        "tool" => name(),
        "command" => "list",
        "exit_code" => 0,
        "stdout" => Enum.join(targets, "\n"),
        "stderr" => "",
        "output_tail" => Enum.join(targets, "\n"),
        "output_tail_lines" => length(targets),
        "truncated" => false,
        "summary" => "Found #{length(targets)} make target(s)."
      }
    else
      {:error, reason} ->
        Map.put(CommandRunner.disallowed(name(), "list", @allowed_commands), "summary", reason)
    end
  end

  defp read_makefile(workdir) do
    ["Makefile", "makefile"]
    |> Enum.map(&Path.join(workdir, &1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> {:error, "No Makefile found."}
      path -> File.read(path)
    end
  end

  defp target(params) do
    value = params |> Map.get("target", "") |> to_string() |> String.trim()

    cond do
      value == "" -> {:error, "target is required for make run."}
      String.starts_with?(value, "-") -> {:error, "make target cannot start with '-'."}
      String.contains?(value, "/") -> {:error, "make target cannot contain '/'."}
      String.match?(value, ~r/\s/) -> {:error, "make target cannot contain whitespace."}
      true -> {:ok, value}
    end
  end

  defp target_line(line) do
    if String.match?(line, ~r/^[A-Za-z0-9_.-]+:/) and not String.contains?(line, "=") do
      line
      |> String.split(":", parts: 2)
      |> List.first()
      |> List.wrap()
    else
      []
    end
  end
end
