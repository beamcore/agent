defmodule Beamcore.Agent.Tools.Tree do
  @moduledoc """
  Tool to show a compact file tree with file sizes.
  """

  @description """
  Show a compact workspace directory tree with sizes. Rejects unsafe paths.
  """

  @ignored_names [
    ".git",
    "_build",
    "deps",
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    ".elixir_ls",
    ".DS_Store"
  ]
  alias Beamcore.Agent.Tools.PathSafety

  def name, do: "tree"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Workspace-relative directory. Defaults to root."
            },
            depth: %{
              type: "integer",
              description: "Maximum depth of the tree. Defaults to 2."
            },
            all: %{
              type: "boolean",
              description: "If true, include hidden and ignored files."
            }
          }
        }
      }
    }
  end

  def execute(params) do
    depth = Map.get(params, "depth", 2)
    show_all = Map.get(params, "all", false)

    with {:ok, path} <- PathSafety.resolve(Map.get(params, "path", ".")) do
      if File.dir?(path) do
        do_tree(path, depth, "", show_all) |> truncate()
      else
        "Error: '#{path}' is not a directory."
      end
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp do_tree(path, depth, indent, show_all) do
    case File.ls(path) do
      {:ok, entries} ->
        entries =
          entries
          |> filter_entries(path, show_all)
          |> Enum.sort()

        {files, dirs} =
          Enum.split_with(entries, fn entry ->
            full_path = Path.join(path, entry)
            !File.dir?(full_path)
          end)

        # Sort: directories first, then files
        sorted_entries = Enum.map(dirs, &{:dir, &1}) ++ Enum.map(files, &{:file, &1})

        lines =
          Enum.map(sorted_entries, fn
            {:dir, name} ->
              full_path = Path.join(path, name)
              line = "#{indent}#{name}/"

              if depth > 1 do
                line <> "\n" <> do_tree(full_path, depth - 1, indent <> "  ", show_all)
              else
                line
              end

            {:file, name} ->
              full_path = Path.join(path, name)
              size = get_size(full_path)
              "#{indent}#{name} (#{size})"
          end)

        Enum.join(lines, "\n")

      {:error, reason} ->
        "#{indent}Error reading directory: #{reason}"
    end
  end

  defp filter_entries(entries, _path, true), do: entries

  defp filter_entries(entries, path, false) do
    entries
    |> Enum.reject(&(&1 in @ignored_names))
    |> filter_git_ignored(path)
  end

  defp filter_git_ignored([], _path), do: []

  defp filter_git_ignored(entries, path) do
    case System.cmd("git", ["check-ignore" | entries], cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        ignored = String.split(output, "\n", trim: true)

        Enum.reject(entries, fn entry ->
          entry in ignored or "#{entry}/" in ignored
        end)

      {_output, 1} ->
        # exit code 1 means nothing was ignored
        entries

      _ ->
        # git might not be available or not a repo
        entries
    end
  end

  defp get_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> format_size(size)
      _ -> "unknown"
    end
  end

  defp format_size(size) when size < 1024, do: "#{size} B"
  defp format_size(size) when size < 1024 * 1024, do: "#{Float.round(size / 1024, 1)} KB"

  defp format_size(size) when size < 1024 * 1024 * 1024,
    do: "#{Float.round(size / (1024 * 1024), 1)} MB"

  defp format_size(size), do: "#{Float.round(size / (1024 * 1024 * 1024), 1)} GB"

  defp truncate(output, max \\ 10_000) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
