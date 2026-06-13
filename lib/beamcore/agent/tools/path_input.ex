defmodule Beamcore.Agent.Tools.PathInput do
  @moduledoc """
  Trusted-local path handling for developer tools.

  This module normalizes user-provided paths for trusted local developer workflows.
  Relative paths are resolved from the configured workspace root/current working
  directory, absolute paths are preserved, and symlinks are allowed. Destructive
  behavior is controlled by the tools that mutate files, not by path normalization.
  """

  @dialyzer {:no_opaque, gitignores_for_path: 1, get_ignores_from_dir: 1}

  @doc """
  Normalizes a user-provided path to an absolute path.
  """
  @spec resolve(binary(), keyword()) :: {:ok, binary()} | {:error, binary()}
  def resolve(path, opts \\ [])

  def resolve(path, opts) when is_binary(path) do
    cwd = Keyword.get(opts, :cwd) || workspace_root()

    path =
      case String.trim(path) do
        "" -> "."
        value -> value
      end

    {:ok, expand(path, cwd)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def resolve(_path, _opts), do: {:error, "path must be a string"}

  @doc """
  Validates glob-style patterns used by file tools.
  """
  @spec validate_pattern(term()) :: :ok | {:error, binary()}
  def validate_pattern(pattern) when is_binary(pattern), do: :ok
  def validate_pattern(_pattern), do: {:error, "pattern must be a string"}

  @doc """
  Formats path errors consistently for tool responses.
  """
  def error(reason), do: "Error: #{reason}"

  @doc """
  Returns the current project root used for relative tool paths.
  """
  def workspace_root do
    configured = Process.get(:workspace_root) || Application.get_env(:agent, :workspace_root)

    cond do
      is_binary(configured) and configured != "" ->
        canonical_path(configured)

      true ->
        case File.cwd() do
          {:ok, cwd} -> canonical_path(cwd)
          {:error, _reason} -> fallback_workspace_root()
        end
    end
  end

  defp fallback_workspace_root do
    initial = Application.get_env(:agent, :initial_workspace_root)

    cond do
      is_binary(initial) and initial != "" -> canonical_path(initial)
      true -> canonical_path(System.tmp_dir!())
    end
  end

  def configure_workspace_root(root) when is_binary(root) do
    root = canonical_path(root)
    previous = Application.get_env(:agent, :workspace_root)
    Application.put_env(:agent, :workspace_root, root)
    previous
  end

  def restore_workspace_root(nil), do: Application.delete_env(:agent, :workspace_root)

  def restore_workspace_root(root) when is_binary(root),
    do: Application.put_env(:agent, :workspace_root, canonical_path(root))

  def canonical_path(path) when is_binary(path) do
    expanded =
      case File.cwd() do
        {:ok, cwd} -> Path.expand(path, cwd)
        {:error, _} -> Path.expand(path, System.user_home!())
      end

    physical_path(expanded)
  end

  @doc """
  Returns a stable journal/display key for an absolute path.

  Paths inside the workspace are stored relative to the workspace. Paths outside
  the workspace remain absolute so external user-requested edits are explicit.
  """
  @spec display_key(binary(), binary()) :: binary()
  def display_key(path, workspace_root) when is_binary(path) and is_binary(workspace_root) do
    absolute = Path.expand(path)
    root = canonical_path(workspace_root)

    if absolute == root or String.starts_with?(absolute, root <> "/") do
      Path.relative_to(absolute, root)
    else
      absolute
    end
  end

  @doc """
  Gets all gitignore ignore patterns for the given directory and project root.
  """
  def gitignores_for_path(path) do
    root = workspace_root()
    ignores = get_ignores_from_dir(root)
    path = Path.expand(path, root)

    ignores =
      if path != root do
        MapSet.union(ignores, get_ignores_from_dir(path))
      else
        ignores
      end

    MapSet.union(ignores, default_ignored())
  end

  @doc """
  Checks if a file is ignored based on the provided ignore patterns relative to a directory.
  """
  def ignored?(file, path, ignored_patterns) do
    rel_path = Path.relative_to(file, path)
    components = Path.split(rel_path)

    if Enum.any?(components, &MapSet.member?(ignored_patterns, &1)) do
      true
    else
      Enum.any?(ignored_patterns, fn pattern ->
        match_pattern?(rel_path, components, pattern)
      end)
    end
  end

  defp expand(path, cwd) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, cwd)
    end
  end

  defp physical_path(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      try do
        case System.cmd("pwd", ["-P"], cd: expanded, stderr_to_stdout: true) do
          {resolved, 0} -> String.trim(resolved)
          _ -> expanded
        end
      rescue
        _ -> expanded
      end
    else
      expanded
    end
  end

  defp default_ignored do
    MapSet.new([
      ".git",
      "_build",
      "deps",
      "node_modules",
      ".venv",
      "venv",
      "__pycache__",
      ".elixir_ls",
      ".beamcore/snapshots",
      ".beamcore/recovery",
      ".beamcore/memory",
      ".DS_Store"
    ])
  end

  defp match_pattern?(rel_path, components, pattern) do
    cond do
      (String.contains?(pattern, "*") or String.contains?(pattern, "?")) and
          not String.contains?(pattern, "/") ->
        regex_str =
          pattern
          |> Regex.escape()
          |> String.replace("\\*", ".*")
          |> String.replace("\\?", ".")

        case Regex.compile("^" <> regex_str <> "$") do
          {:ok, regex} -> Enum.any?(components, &Regex.match?(regex, &1))
          _ -> false
        end

      String.contains?(pattern, "/") ->
        regex_str =
          pattern
          |> Regex.escape()
          |> String.replace("\\*", ".*")
          |> String.replace("\\?", ".")
          |> then(&(&1 <> "(?:/.*)?"))

        case Regex.compile("^" <> regex_str <> "$") do
          {:ok, regex} -> Regex.match?(regex, rel_path)
          _ -> false
        end

      true ->
        false
    end
  end

  defp get_ignores_from_dir(dir) do
    gitignore = Path.join(dir, ".gitignore")

    if File.exists?(gitignore) do
      gitignore
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
      |> Enum.map(fn line ->
        line
        |> String.trim_trailing("/")
        |> String.trim_leading("/")
      end)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end
end
