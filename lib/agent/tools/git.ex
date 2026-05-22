defmodule Beamcore.Agent.Tools.Git do
  @moduledoc """
  Tool to perform git operations.
  """
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Execute common git operations: clone, add, status, restore, log, diff, and commit.
  For log queries, it returns the two latest commits to keep context compact.
  Use this whenever you need to interact with the repository's git version control.
  Workdirs and path arguments must stay inside the current workspace.
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
              description: "The git operation to perform."
            },
            path: %{
              type: "string",
              description: "The file or directory path for operations like add, restore, diff."
            },
            url: %{
              type: "string",
              description: "The repository URL for clone."
            },
            message: %{
              type: "string",
              description: "The commit message for commit operation."
            },
            workdir: %{
              type: "string",
              description:
                "The directory to run the git command in. Defaults to current directory."
            },
            staged: %{
              type: "boolean",
              description: "If true, show staged changes for diff. Defaults to false."
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
        url = Map.get(params, "url")

        if url do
          path = Map.get(params, "path")

          with :ok <- validate_optional_path(path) do
            args = if path, do: ["clone", url, path], else: ["clone", url]
            run_git(args, workdir)
          else
            {:error, reason} -> PathSafety.error(reason)
          end
        else
          "Error: url is required for clone operation."
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
        path = Map.get(params, "path")

        if path do
          with :ok <- PathSafety.validate_pattern(path) do
            run_git(["restore", path], workdir)
          else
            {:error, reason} -> PathSafety.error(reason)
          end
        else
          "Error: path is required for restore operation."
        end

      "log" ->
        run_git(["log", "-n", "2"], workdir)

      "diff" ->
        staged = Map.get(params, "staged", false)
        path = Map.get(params, "path")
        args = ["diff"]
        args = if staged, do: args ++ ["--staged"], else: args

        with :ok <- validate_optional_path(path) do
          args = if path, do: args ++ [path], else: args
          run_git(args, workdir)
        else
          {:error, reason} -> PathSafety.error(reason)
        end

      "commit" ->
        message = Map.get(params, "message")

        if message do
          run_git(["commit", "-m", message], workdir)
        else
          "Error: message is required for commit operation."
        end

      _ ->
        "Error: Unsupported git operation: #{operation}"
    end
  end

  defp validate_optional_path(nil), do: :ok
  defp validate_optional_path(path), do: PathSafety.validate_pattern(path)

  defp run_git(args, workdir) do
    case System.cmd("git", args, cd: workdir, stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) == "" do
          "Success (no output)"
        else
          truncate(output)
        end

      {output, _exit_code} ->
        "Error: #{truncate(output)}"
    end
  end

  defp truncate(output, max \\ 10_000) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
