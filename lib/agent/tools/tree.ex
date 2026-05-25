defmodule Beamcore.Agent.Tools.Tree do
  @moduledoc """
  Tool to show a compact file tree with file sizes.
  """

  @description """
  Show a compact workspace directory tree with sizes. Rejects unsafe paths.
  """

  alias Beamcore.Agent.Policy.ProjectPolicy
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
            }
          }
        }
      }
    }
  end

  def execute(params) do
    show_all = Map.get(params, "all", false)

    requested_path = Map.get(params, "path", ".")

    with :ok <- ProjectPolicy.allowed_read_path?(requested_path),
         {:ok, path} <- PathSafety.resolve(requested_path) do
      if File.dir?(path) do
        ignored = if show_all, do: MapSet.new(), else: PathSafety.gitignores_for_path(path)
        do_tree(path, path, "", show_all, ignored) |> truncate()
      else
        "Error: '#{path}' is not a directory."
      end
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp do_tree(path, root_path, indent, show_all, ignored) do
    case File.ls(path) do
      {:ok, entries} ->
        entries =
          entries
          |> filter_entries(path, root_path, show_all, ignored)
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

              line <>
                "\n" <>
                do_tree(full_path, root_path, indent <> "  ", show_all, ignored)

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

  defp filter_entries(entries, path, _root_path, true, _ignored) do
    Enum.reject(entries, &ProjectPolicy.denied_path?(Path.join(path, &1)))
  end

  defp filter_entries(entries, path, root_path, false, ignored) do
    entries
    |> Enum.reject(fn entry ->
      full_path = Path.join(path, entry)
      PathSafety.ignored?(full_path, root_path, ignored) or ProjectPolicy.denied_path?(full_path)
    end)
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
