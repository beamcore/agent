defmodule Beamcore.Agent.Tools.Grep do
  @moduledoc """
  Workspace-bounded content search tool.
  """

  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Search file contents by regular expression inside workspace-relative paths.
  Supports optional include glob filtering, pagination, and a built-in Elixir fallback when ripgrep is unavailable.
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
              description:
                "The workspace-relative file or directory to search in. Defaults to the workspace root."
            },
            include: %{
              type: "string",
              description: "File pattern to include in the search, for example '*.ex'"
            },
            all: %{
              type: "boolean",
              description: "If true, search hidden and ignored files. Defaults to false."
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

    with :ok <- PathSafety.validate_pattern(include || "*"),
         {:ok, safe_path} <- PathSafety.resolve(path) do
      do_execute(pattern, safe_path, include, show_all, offset, limit)
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp do_execute(pattern, path, include, show_all, offset, limit) do
    case rg_execute(pattern, path, include, show_all) do
      {:ok, output} -> paginate_output(output, offset, limit)
      {:nomatch, output} when output != "" -> paginate_output(output, offset, limit)
      {:nomatch, _output} -> "No matches found."
      {:unavailable, _reason} -> fallback_execute(pattern, path, include, show_all, offset, limit)
      {:error, output} -> "Error running grep: #{truncate(output)}"
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
      {:ok, output, 0} ->
        output = filter_ignored_output(output, path, show_all)
        if output == "", do: {:nomatch, output}, else: {:ok, output}

      {:ok, output, 1} ->
        {:nomatch, filter_ignored_output(output, path, show_all)}

      {:ok, output, _exit_code} ->
        {:error, output}

      {:error, reason} ->
        {:unavailable, reason}
    end
  end

  defp filter_ignored_output(output, _path, true), do: output

  defp filter_ignored_output(output, path, false) do
    ignored = ignored_names(path)

    if MapSet.size(ignored) == 0 do
      output
    else
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(fn line ->
        file =
          line
          |> String.split(":", parts: 2)
          |> List.first()

        MapSet.member?(ignored, Path.basename(file))
      end)
      |> Enum.join("\n")
    end
  end

  defp fallback_execute(pattern, path, include, show_all, offset, limit) do
    regex = Regex.compile!(pattern)

    output =
      path
      |> candidate_files(include, show_all)
      |> Enum.flat_map(&grep_file(&1, regex))
      |> Enum.join("\n")

    if output == "" do
      "No matches found."
    else
      paginate_output(output, offset, limit)
    end
  rescue
    e -> "Error running grep fallback: #{Exception.message(e)}"
  end

  defp candidate_files(path, include, show_all) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        ignored = if show_all, do: MapSet.new(), else: ignored_names(path)

        path
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: show_all)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&(Path.basename(&1) in ignored))
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

  defp paginate_output(output, offset, limit) do
    lines = String.split(output, "\n", trim: true)
    total_lines = length(lines)
    start_idx = max(0, offset - 1)
    sliced_lines = Enum.slice(lines, start_idx, limit)
    shown_count = length(sliced_lines)
    left_count = total_lines - (start_idx + shown_count)

    result = Enum.join(sliced_lines, "\n")

    cond do
      total_lines == 0 ->
        "No matches found."

      left_count > 0 ->
        last = offset + shown_count - 1
        next = last + 1

        result <>
          "\n\n(Showing matches #{offset}-#{last}. #{left_count} matches left. Use offset=#{next} to continue.)"

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
