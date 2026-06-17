defmodule Beamcore.TUI.FileFinder.Loader do
  @moduledoc false

  alias Beamcore.Agent.Tools.PathInput
  alias Beamcore.Agent.SafeCmd

  @doc """
  Loads the list of workspace files and directories, respecting .gitignore.
  Tries git ls-files, then rg --files, then Path.wildcard as fallback.
  Directories are derived from file paths and suffixed with `/`.
  Filters out noisy internal/build paths.
  """
  @spec load_files() :: [String.t()]
  def load_files do
    root = PathInput.workspace_root()

    file_paths =
      case git_ls_files(root) do
        {:ok, paths} -> paths
        {:error, _} -> rg_files_fallback(root)
      end

    dirs = extract_directories(file_paths)

    (file_paths ++ dirs)
    |> Enum.filter(&safe_workspace_entry?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_directories(file_paths) do
    file_paths
    |> Enum.flat_map(fn path ->
      parts = path |> Path.split() |> Enum.drop(-1)

      parts
      |> Enum.scan(fn segment, acc -> acc <> "/" <> segment end)
    end)
    |> MapSet.new()
    |> Enum.map(&(&1 <> "/"))
  end

  defp git_ls_files(root) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard"]

    case SafeCmd.run("git", args, cd: root, stderr_to_stdout: true, timeout: 10_000) do
      {:ok, output, 0} ->
        case String.split(output, "\n", trim: true) do
          [] -> {:error, :no_files}
          paths -> {:ok, paths}
        end

      _ ->
        {:error, :git_failed}
    end
  end

  defp rg_files_fallback(root) do
    case SafeCmd.run("rg", ["--files", "--follow", root], stderr_to_stdout: true, timeout: 10_000) do
      {:ok, output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> relativize(root)

      _ ->
        root
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> relativize(root)
    end
  end

  defp relativize(paths, root) do
    root_prefix = if String.ends_with?(root, "/"), do: root, else: root <> "/"

    Enum.map(paths, fn path ->
      if String.starts_with?(path, root_prefix) do
        String.trim_leading(path, root_prefix)
      else
        path
      end
    end)
  end

  defp safe_workspace_entry?(path) do
    normalized =
      path
      |> String.trim_trailing("/")
      |> Path.split()
      |> Enum.join("/")
      |> String.downcase()

    not Enum.any?(
      [
        ".git",
        "_build",
        "deps",
        "node_modules",
        ".elixir_ls",
        ".beamcore/snapshots",
        ".beamcore/recovery",
        ".beamcore/memory"
      ],
      fn hidden -> normalized == hidden or String.starts_with?(normalized, hidden <> "/") end
    )
  end
end
