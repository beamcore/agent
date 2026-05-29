defmodule Beamcore.Agent.Tools.Make do
  @moduledoc """
  Allowlisted Make workflow tool.
  """

  alias Beamcore.Agent.Tools.{CommandRunner, PathSafety}

  @allowed_commands ~w(list run)
  @description """
  Discover Makefile targets from project text or run one discovered target. Make
  targets are project-defined and remain ProjectPolicy-controllable at the tool level.
  """
  @makefiles ~w(Makefile makefile GNUmakefile)

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
            workdir: %{type: "string", description: "Workspace-relative workdir"}
          },
          required: ["command"]
        }
      }
    }
  end

  def execute(%{"command" => "list"} = params), do: list_targets(params) |> CommandRunner.encode()

  def execute(%{"command" => "run"} = params) do
    with {:ok, safe_workdir} <- safe_workdir(params),
         {:ok, _makefile_path, content} <- read_makefile(safe_workdir),
         targets = discover_targets(content),
         {:ok, target} <- target(params, targets) do
      CommandRunner.run(
        name(),
        "run",
        "make",
        [target],
        workdir: workdir_param(params)
      )
      |> CommandRunner.encode()
    else
      {:error, reason} ->
        reason
        |> disallowed("run")
        |> CommandRunner.encode()
    end
  end

  def execute(%{"command" => command}),
    do: CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()

  def discover_targets(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(&target_line/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp list_targets(params) do
    with {:ok, safe_workdir} <- safe_workdir(params),
         {:ok, makefile_path, content} <- read_makefile(safe_workdir) do
      targets = discover_targets(content)
      output = Enum.join(targets, "\n")

      %{
        "ok" => true,
        "tool" => name(),
        "command" => "list",
        "exit_code" => 0,
        "makefile" => Path.relative_to(makefile_path, PathSafety.workspace_root()),
        "targets" => targets,
        "stdout" => output,
        "stderr" => "",
        "output_tail" => output,
        "output_tail_lines" => length(targets),
        "truncated" => false,
        "summary" => "Found #{length(targets)} make target(s)."
      }
    else
      {:error, reason} ->
        disallowed(reason, "list")
    end
  end

  defp safe_workdir(params), do: params |> workdir_param() |> PathSafety.resolve()

  defp workdir_param(params), do: Map.get(params, "workdir", ".")

  defp read_makefile(workdir) do
    @makefiles
    |> Enum.map(&Path.join(workdir, &1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> {:error, "No Makefile found."}
      path -> with {:ok, content} <- File.read(path), do: {:ok, path, content}
    end
  end

  defp target(params, targets) do
    value = params |> Map.get("target", "") |> to_string() |> String.trim()

    cond do
      value == "" -> {:error, "target is required for make run."}
      not safe_target?(value) -> {:error, "Unsafe make target: #{value}"}
      value not in targets -> {:error, "Unknown make target: #{value}"}
      true -> {:ok, value}
    end
  end

  defp target_line(line) do
    line =
      line
      |> String.split("#", parts: 2)
      |> List.first()
      |> String.trim()

    cond do
      line == "" ->
        []

      String.starts_with?(line, ".PHONY:") ->
        line
        |> String.replace_prefix(".PHONY:", "")
        |> split_targets()

      special_target?(line) or assignment?(line) or not String.contains?(line, ":") ->
        []

      true ->
        line
        |> String.split(":", parts: 2)
        |> List.first()
        |> split_targets()
    end
  end

  defp split_targets(targets) do
    targets
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&safe_target?/1)
  end

  defp assignment?(line) do
    String.match?(line, ~r/^[A-Za-z_][A-Za-z0-9_.-]*\s*(?::=|\+=|\?=|=)/)
  end

  defp special_target?("." <> _rest), do: true
  defp special_target?(_line), do: false

  defp safe_target?(target) do
    String.match?(target, ~r/^[A-Za-z0-9_.-]+$/) and
      not String.starts_with?(target, "-") and
      not String.starts_with?(target, ".") and
      not String.contains?(target, "..") and
      not String.contains?(target, "%")
  end

  defp disallowed(reason, command) do
    Map.put(CommandRunner.disallowed(name(), command, @allowed_commands), "summary", reason)
  end
end
