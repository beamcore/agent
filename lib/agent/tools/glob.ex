defmodule Beamcore.Agent.Tools.Glob do
  @moduledoc """
  Workspace-bounded file globbing tool.
  """

  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.{CommandRunner, PathSafety}

  @description """
  Find workspace files matching a glob pattern, e.g. "**/*.ex", relative to a path.
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
              description: "The glob pattern to match, for example '**/*.ex'"
            },
            path: %{
              type: "string",
              description: "Workspace-relative directory to search in. Defaults to root."
            },
            all: %{
              type: "boolean",
              description: "If true, include hidden/ignored files. Defaults to false."
            },
            offset: %{
              type: "integer",
              description: "Start entry index, 1-indexed. Defaults to 1."
            },
            limit: %{
              type: "integer",
              description: "Maximum matches to return. Defaults to 100."
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
    offset = Map.get(params, "offset", 1)
    limit = Map.get(params, "limit", 100)

    with :ok <- ProjectPolicy.allowed_read_path?(path),
         :ok <- PathSafety.validate_pattern(pattern),
         {:ok, safe_path} <- PathSafety.resolve(path) do
      do_execute(pattern, safe_path, show_all, offset, limit)
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp do_execute(pattern, path, show_all, offset, limit) do
    result =
      if show_all do
        case execute_rg(pattern, path, true) do
          {:ok, paths} -> {:ok, paths}
          {:error, _} -> {:ok, fallback_glob(pattern, path, true)}
        end
      else
        case execute_git_ls(pattern, path) do
          {:ok, paths} ->
            {:ok, paths}

          {:error, _} ->
            case execute_rg(pattern, path, false) do
              {:ok, paths} -> {:ok, paths}
              {:error, _} -> {:ok, fallback_glob(pattern, path, false)}
            end
        end
      end

    case result do
      {:ok, paths} ->
        paths
        |> relativize_paths(path)
        |> Enum.reject(&ProjectPolicy.denied_path?/1)
        |> Enum.sort()
        |> paginate_output(pattern, path, offset, limit)
    end
  end

  defp execute_rg(pattern, path, show_all) do
    common_args = ["--files", "--glob", pattern]
    args = if show_all, do: ["--hidden", "--no-ignore" | common_args], else: common_args

    case safe_cmd("rg", args ++ [path], stderr_to_stdout: true) do
      {:ok, output, 0} ->
        {:ok, String.split(output, "\n", trim: true)}

      {:ok, _output, 1} ->
        {:ok, []}

      {:ok, output, _exit_code} ->
        {:error, output}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_git_ls(pattern, path) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard", pattern]

    case safe_cmd("git", args, cd: path, stderr_to_stdout: true) do
      {:ok, output, 0} ->
        case String.split(output, "\n", trim: true) do
          [] -> {:error, :no_matches}
          paths -> {:ok, paths}
        end

      {:ok, _output, _} ->
        {:error, :git_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fallback_glob(pattern, path, show_all) do
    ignored = if show_all, do: MapSet.new(), else: PathSafety.gitignores_for_path(path)

    path
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: show_all)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(PathSafety.ignored?(&1, path, ignored) or ProjectPolicy.denied_path?(&1)))
  end

  defp no_files(pattern, path), do: "No files found matching pattern: #{pattern} in #{path}"

  defp relativize_paths(paths, path) do
    root = PathSafety.workspace_root()
    root_prefix = if String.ends_with?(root, "/"), do: root, else: root <> "/"
    root_len = String.length(root_prefix)
    abs_path = Path.expand(path)

    paths
    |> Enum.map(fn file ->
      abs_file = Path.expand(file, abs_path)

      if String.starts_with?(abs_file, root_prefix) do
        String.slice(abs_file, root_len..-1//1)
      else
        abs_file
      end
    end)
  end

  defp paginate_output(paths, pattern, path, offset, limit) do
    total_lines = length(paths)
    start_idx = max(0, offset - 1)
    sliced_lines = Enum.slice(paths, start_idx, limit)
    shown_count = length(sliced_lines)
    left_count = max(0, total_lines - (start_idx + shown_count))

    result = Enum.join(sliced_lines, "\n")

    cond do
      total_lines == 0 ->
        no_files(pattern, path)

      left_count > 0 ->
        last = offset + shown_count - 1

        result <>
          "\n\n(Showing matches #{offset}-#{last}. #{left_count} matches left. Use offset=#{last + 1} to continue.)"

      result == "" ->
        "(Offset #{offset} is out of range. #{total_lines} matches found.)"

      true ->
        result
    end
  end

  defp safe_cmd(command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {:error, :enoent}

      _path ->
        try do
          opts = Keyword.put(opts, :env, CommandRunner.external_env(Keyword.get(opts, :env, [])))
          {output, exit_code} = System.cmd(command, args, opts)
          {:ok, output, exit_code}
        rescue
          e in ErlangError -> {:error, e.original}
        end
    end
  end
end
