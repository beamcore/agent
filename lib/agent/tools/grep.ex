defmodule Beamcore.Agent.Tools.Grep do
  @moduledoc """
  Workspace-bounded content search tool.
  """

  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.{CommandRunner, PathSafety}

  @description """
  Search workspace file contents by regex with optional include, offset, and limit.
  """

  def name, do: "grep"

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
              description: "The regex pattern to search for in file contents"
            },
            path: %{
              type: "string",
              description: "Workspace-relative file or directory. Defaults to root."
            },
            include: %{
              type: "string",
              description: "File pattern to include in the search, for example '*.ex'"
            },
            all: %{
              type: "boolean",
              description: "If true, include hidden and ignored files."
            },
            offset: %{
              type: "integer",
              description: "The match number to start reading from (1-indexed)"
            },
            limit: %{
              type: "integer",
              description: "The maximum number of matches to return (defaults to 50)"
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
    include = Map.get(params, "include")
    show_all = Map.get(params, "all", false)
    offset = Map.get(params, "offset", 1)
    limit = Map.get(params, "limit", 50)

    with :ok <- ProjectPolicy.allowed_read_path?(path),
         :ok <- PathSafety.validate_pattern(include || "*"),
         {:ok, safe_path} <- PathSafety.resolve(path) do
      do_execute(pattern, safe_path, include, show_all, offset, limit)
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp do_execute(pattern, path, include, show_all, offset, limit) do
    case rg_execute(pattern, path, include, show_all) do
      {:ok, output} ->
        output
        |> relativize_output()
        |> paginate_output(offset, limit)

      {:nomatch, _} ->
        "No matches found."

      {:unavailable, _} ->
        fallback_execute(pattern, path, include, show_all, offset, limit)

      {:error, output} ->
        "Error running grep: #{truncate(output)}"
    end
  end

  defp rg_execute(pattern, path, include, show_all) do
    common_args = [
      "--line-number",
      "--with-filename",
      "--no-heading",
      "--color=never",
      "--sortr=modified",
      "-e",
      pattern
    ]

    common_args = if show_all, do: ["--no-ignore", "--hidden" | common_args], else: common_args
    args = if include, do: ["-g", include | common_args], else: common_args

    case safe_cmd("rg", args ++ [path], stderr_to_stdout: true) do
      {:ok, output, exit_code} when exit_code in [0, 1] ->
        filtered = filter_ignored_output(output, path, show_all)
        if filtered == "", do: {:nomatch, ""}, else: {:ok, filtered}

      {:ok, output, _exit_code} ->
        {:error, output}

      {:error, reason} ->
        {:unavailable, reason}
    end
  end

  defp filter_ignored_output(output, path, true), do: filter_policy_denied_output(output, path)

  defp filter_ignored_output(output, path, false) do
    ignored = PathSafety.gitignores_for_path(path)

    output
    |> String.split("\n", trim: true)
    |> Enum.reject(fn line ->
      file =
        line
        |> String.split(":", parts: 2)
        |> List.first()

      PathSafety.ignored?(file, path, ignored) or ProjectPolicy.denied_path?(file)
    end)
    |> Enum.join("\n")
  end

  defp filter_policy_denied_output(output, _path) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(fn line ->
      file =
        line
        |> String.split(":", parts: 2)
        |> List.first()

      ProjectPolicy.denied_path?(file)
    end)
    |> Enum.join("\n")
  end

  defp fallback_execute(pattern, path, include, show_all, offset, limit) do
    regex = Regex.compile!(pattern)

    path
    |> candidate_files(include, show_all)
    |> Enum.flat_map(&grep_file(&1, regex))
    |> Enum.join("\n")
    |> relativize_output()
    |> paginate_output(offset, limit)
  rescue
    e -> "Error running grep fallback: #{Exception.message(e)}"
  end

  defp candidate_files(path, include, show_all) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        ignored = if show_all, do: MapSet.new(), else: PathSafety.gitignores_for_path(path)

        path
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: show_all)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(
          &(PathSafety.ignored?(&1, path, ignored) or ProjectPolicy.denied_path?(&1))
        )
        |> filter_include(include)

      true ->
        []
    end
  end

  defp filter_include(files, nil), do: files

  defp filter_include(files, include) do
    regex = glob_regex(include)
    Enum.filter(files, &(Regex.match?(regex, Path.basename(&1)) or Regex.match?(regex, &1)))
  end

  defp grep_file(path, regex) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      clean = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")

      if Regex.match?(regex, clean) do
        ["#{path}:#{line_number}:#{clean}"]
      else
        []
      end
    end)
  rescue
    _ -> []
  end

  defp relativize_output(output) do
    root = PathSafety.workspace_root() <> "/"
    root_len = String.length(root)

    output
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", fn line ->
      if String.starts_with?(line, root) do
        String.slice(line, root_len..-1//1)
      else
        line
      end
    end)
  end

  defp paginate_output(output, offset, limit) do
    lines = String.split(output, "\n", trim: true)
    total_lines = length(lines)
    start_idx = max(0, offset - 1)
    sliced_lines = Enum.slice(lines, start_idx, limit)
    shown_count = length(sliced_lines)
    left_count = max(0, total_lines - (start_idx + shown_count))

    result = Enum.join(sliced_lines, "\n")

    cond do
      total_lines == 0 ->
        "No matches found."

      left_count > 0 ->
        last = offset + shown_count - 1

        result <>
          "\n\n(Showing matches #{offset}-#{last}. #{left_count} matches left. Use offset=#{last + 1} to continue.)"

      result == "" ->
        "(Offset #{offset} is out of range. #{total_lines} matches found.)"

      true ->
        result <> "\n\n(#{total_lines} matches found. End of matches.)"
    end
  end

  defp glob_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", ".")
    |> then(&Regex.compile!("^#{&1}$"))
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

  defp truncate(output, max \\ 10_000) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
