defmodule Beamcore.Agent.Tools.Glob do
  @moduledoc """
  Tool to find files by glob pattern.
  """
  @description """
  Find file paths matching a specific glob pattern such as "**/*.ex" in a directory.
  Optionally returns hidden and ignored files based on the specified parameters.
  Always returns full absolute paths to ensure target files are accurately resolved.
  """

  def name, do: "glob"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "The glob pattern to match against (e.g., '**/*.ex')"
            },
            path: %{
              type: "string",
              description: "The directory to search in. Defaults to current directory."
            },
            all: %{
              type: "boolean",
              description: "If true, show hidden and ignored files. Defaults to false."
            }
          },
          required: ["pattern"]
        }
      }
    }
  end

  def execute(params) do
    pattern = Map.fetch!(params, "pattern")
    path = Map.get(params, "path", ".")
    show_all = Map.get(params, "all", false)

    if show_all do
      execute_rg_all(pattern, path)
    else
      case execute_git_ls(pattern, path) do
        {:ok, output} -> output
        {:error, _} -> execute_rg_filtered(pattern, path)
      end
    end
  end

  defp execute_rg_all(pattern, path) do
    args = ["--files", "--hidden", "--no-ignore", "--glob", pattern, path]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} -> format_output(output, path)
      {_output, 1} -> "No files found matching pattern: #{pattern} in #{path}"
      {output, _} -> "Error running glob (rg): #{output}"
    end
  end

  defp execute_git_ls(pattern, path) do
    # git ls-files respects .gitignore and matches the pattern correctly without overriding
    args = ["ls-files", "--cached", "--others", "--exclude-standard", pattern]

    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) == "" do
          {:ok, "No files found matching pattern: #{pattern} in #{path}"}
        else
          {:ok, format_output(output, path)}
        end

      {output, _} ->
        {:error, output}
    end
  end

  defp execute_rg_filtered(pattern, path) do
    # Fallback: list all files and filter manually if not in a git repo
    # Note: rg --files respects .gitignore
    case System.cmd("rg", ["--files", path], stderr_to_stdout: true) do
      {output, 0} ->
        # We use a simple filtering here, might not be as good as git's globbing
        # but better than nothing.
        filtered =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&match_pattern?(&1, pattern))

        if filtered == [] do
          "No files found matching pattern: #{pattern} in #{path}"
        else
          Enum.join(filtered, "\n")
        end

      {_output, 1} ->
        "No files found matching pattern: #{pattern} in #{path}"

      {output, _} ->
        "Error running glob (fallback): #{output}"
    end
  end

  defp format_output(output, path) do
    abs_path = Path.expand(path)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      Path.expand(line, abs_path)
    end)
    |> Enum.join("\n")
  end

  defp match_pattern?(path, pattern) do
    # Simple glob to regex conversion for fallback
    regex_pattern =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")
      |> String.replace("?", ".")
      |> then(&"^#{&1}$")
      |> Regex.compile!()

    Regex.run(regex_pattern, Path.basename(path)) != nil or
      Regex.run(regex_pattern, path) != nil
  end
end
