defmodule Beamcore.Agent.Tools.Git do
  @moduledoc """
  Tool to perform git operations within the workspace safely.
  """
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Run explicit git operations inside the workspace. Log returns up to limit commits.
  """

  def name, do: "git"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            operation: %{
              type: "string",
              enum: ["clone", "add", "status", "restore", "log", "diff", "commit"],
              description: "Git operation to run."
            },
            path: %{
              type: "string",
              description: "Target file/directory path (relative to workdir)."
            },
            url: %{
              type: "string",
              description: "Repository URL for clone."
            },
            message: %{
              type: "string",
              description: "Commit message for commit."
            },
            workdir: %{
              type: "string",
              description: "Workspace-relative workdir (defaults to root)."
            },
            staged: %{
              type: "boolean",
              description: "If true, show staged changes for diff."
            },
            limit: %{
              type: "integer",
              description: "Max commits to return for log. Defaults to 5."
            },
            base: %{
              type: "string",
              description: "Base revision/branch to compare or log against (e.g. origin/main)."
            }
          },
          required: ["operation"]
        }
      }
    }
  end

  def execute(params) do
    operation = Map.fetch!(params, "operation")
    workdir = Map.get(params, "workdir", ".")

    with {:ok, safe_workdir} <- PathSafety.resolve(workdir) do
      execute_operation(operation, params, safe_workdir)
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp execute_operation(operation, params, workdir) do
    case operation do
      "clone" ->
        case Map.get(params, "url") do
          nil ->
            "Error: url is required for clone operation."

          url ->
            path = Map.get(params, "path")

            with :ok <- validate_optional_path(path) do
              args = if path, do: ["clone", url, path], else: ["clone", url]
              run_git(args, workdir)
            else
              {:error, reason} -> PathSafety.error(reason)
            end
        end

      "add" ->
        path = Map.get(params, "path") || "."

        with :ok <- PathSafety.validate_pattern(path) do
          run_git(["add", path], workdir)
        else
          {:error, reason} -> PathSafety.error(reason)
        end

      "status" ->
        run_git(["status"], workdir)

      "restore" ->
        case Map.get(params, "path") do
          nil ->
            "Error: path is required for restore operation."

          path ->
            with :ok <- PathSafety.validate_pattern(path) do
              run_git(["restore", path], workdir)
            else
              {:error, reason} -> PathSafety.error(reason)
            end
        end

      "log" ->
        limit = Map.get(params, "limit", 5)
        base = Map.get(params, "base")

        with :ok <- validate_revision(base) do
          args = ["log", "-n", to_string(limit)]
          args = if base, do: args ++ [base], else: args
          run_git(args, workdir)
        else
          {:error, reason} -> PathSafety.error(reason)
        end

      "diff" ->
        staged = Map.get(params, "staged", false)
        base = Map.get(params, "base")
        path = Map.get(params, "path")

        with :ok <- validate_revision(base),
             :ok <- validate_optional_path(path) do
          args = ["diff"]
          args = if staged, do: args ++ ["--staged"], else: args
          args = if base, do: args ++ [base], else: args
          args = if path, do: args ++ ["--", path], else: args

          run_git(args, workdir)
        else
          {:error, reason} -> PathSafety.error(reason)
        end

      "commit" ->
        case Map.get(params, "message") do
          nil ->
            "Error: message is required for commit operation."

          message ->
            # Dynamic git configuration overrides to ensure commit succeeds even in environments with missing git configuration.
            args = [
              "-c",
              "user.name=Beamcore Agent",
              "-c",
              "user.email=agent@beamcore.dev",
              "commit",
              "-m",
              message
            ]

            run_git(args, workdir)
        end

      _ ->
        "Error: Unsupported git operation: #{operation}"
    end
  end

  defp validate_optional_path(nil), do: :ok
  defp validate_optional_path(path), do: PathSafety.validate_pattern(path)

  defp validate_revision(nil), do: :ok

  defp validate_revision(rev) when is_binary(rev) do
    if String.starts_with?(rev, "-") do
      {:error, "revision cannot start with '-'"}
    else
      :ok
    end
  end

  defp validate_revision(_), do: {:error, "revision must be a string"}

  defp run_git(args, workdir) do
    case System.find_executable("git") do
      nil ->
        "Error: git executable not found in system PATH."

      _path ->
        try do
          case System.cmd("git", args, cd: workdir, stderr_to_stdout: true) do
            {output, 0} ->
              if String.trim(output) == "" do
                "Success (no output)"
              else
                truncate(output)
              end

            {output, exit_code} ->
              trimmed = String.trim(output)

              if trimmed == "" do
                "Error: Command failed with exit code #{exit_code} (no output)"
              else
                "Error: #{truncate(trimmed)}"
              end
          end
        rescue
          e in ErlangError ->
            "Error: OS error executing git: #{inspect(e.original)}"

          e ->
            "Error: Unexpected execution failure: #{Exception.message(e)}"
        end
    end
  end

  defp truncate(output, max \\ 100_000) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
