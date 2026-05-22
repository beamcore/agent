defmodule Beamcore.Agent.Tools.Glob do
  @moduledoc """
  Workspace-bounded file globbing tool.
  """

  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Find workspace files matching a glob pattern such as "**/*.ex".
  Respects workspace boundaries and includes an Elixir fallback when ripgrep is unavailable.
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
              description: "The workspace-safe glob pattern to match, for example '**/*.ex'"
            },
            path: %{
              type: "string",
              description:
                "The workspace-relative directory to search in. Defaults to workspace root."
            },
            all: %{
              type: "boolean",
              description: "If true, include hidden and ignored files. Defaults to false."
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

    with :ok <- PathSafety.validate_pattern(pattern),
         {:ok, safe_path} <- PathSafety.resolve(path) do
      do_execute(pattern, safe_path, show_all)
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp do_execute(pattern, path, show_all) do
    if show_all do
      case execute_rg_all(pattern, path) do
        {:ok, output} -> output
        {:error, :enoent} -> fallback_glob(pattern, path, show_all)
        {:error, output} -> "Error running glob (rg): #{output}"
      end
    else
      case execute_git_ls(pattern, path) do
        {:ok, output} -> output
        {:error, _} -> execute_rg_or_fallback(pattern, path, show_all)
      end
    end
  end

  defp execute_rg_all(pattern, path) do
    args = ["--files", "--hidden", "--no-ignore", "--glob", pattern, path]

    case safe_cmd("rg", args, stderr_to_stdout: true) do
      {:ok, output, 0} -> {:ok, format_output(output, path)}
      {:ok, _output, 1} -> {:ok, no_files(pattern, path)}
      {:ok, output, _} -> {:error, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_git_ls(pattern, path) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard", pattern]

    case safe_cmd("git", args, cd: path, stderr_to_stdout: true) do
      {:ok, output, 0} ->
        if String.trim(output) == "" do
          {:error, :no_matches}
        else
          {:ok, format_output(output, path)}
        end

      {:ok, output, _} ->
        {:error, output}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_rg_or_fallback(pattern, path, show_all) do
    case safe_cmd("rg", ["--files", path], stderr_to_stdout: true) do
      {:ok, output, 0} ->
        filtered =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&match_pattern?(&1, pattern))

        if filtered == [] do
          no_files(pattern, path)
        else
          Enum.join(filtered, "\n")
        end

      {:ok, _output, 1} ->
        no_files(pattern, path)

      {:ok, _output, _} ->
        fallback_glob(pattern, path, show_all)

      {:error, _reason} ->
        fallback_glob(pattern, path, show_all)
    end
  end

  defp fallback_glob(pattern, path, show_all) do
    ignored = if show_all, do: MapSet.new(), else: ignored_names(path)

    matches =
      path
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: show_all)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&(Path.basename(&1) in ignored))

    if matches == [] do
      no_files(pattern, path)
    else
      Enum.join(matches, "\n")
    end
  end

  defp ignored_names(path) do
    gitignore = Path.join(path, ".gitignore")

    if File.exists?(gitignore) do
      gitignore
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp no_files(pattern, path), do: "No files found matching pattern: #{pattern} in #{path}"

  defp format_output(output, path) do
    abs_path = Path.expand(path)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Path.expand(&1, abs_path))
    |> Enum.join("\n")
  end

  defp match_pattern?(path, pattern) do
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", ".")
      |> then(&"^#{&1}$")
      |> Regex.compile!()

    Regex.match?(regex_pattern, Path.basename(path)) or Regex.match?(regex_pattern, path)
  end

  defp safe_cmd(command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {:error, :enoent}

      _path ->
        try do
          {output, exit_code} = System.cmd(command, args, opts)
          {:ok, output, exit_code}
        rescue
          e in ErlangError -> {:error, e.original}
        end
    end
  end
end
