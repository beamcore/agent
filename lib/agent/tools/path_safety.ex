defmodule Beamcore.Agent.Tools.PathSafety do
  @moduledoc """
  Resolves user-provided tool paths inside the current workspace.
  """

  @doc """
  Resolve a relative path to an absolute path inside the workspace.
  """
  def resolve(path, opts \\ [])

  def resolve(path, opts) when is_binary(path) do
    allow_missing = Keyword.get(opts, :allow_missing, false)
    root = workspace_root()

    cleaned_path =
      cond do
        path == "/" or String.trim(path) == "" ->
          "."

        path == root ->
          "."

        String.starts_with?(path, root <> "/") ->
          Path.relative_to(path, root)

        true ->
          path
      end

    with :ok <- reject_absolute(cleaned_path),
         :ok <- reject_traversal(cleaned_path) do
      candidate = Path.expand(cleaned_path, root)

      with :ok <- ensure_inside_workspace(candidate, root),
           :ok <- ensure_symlinks_inside(candidate, root, allow_missing) do
        {:ok, candidate}
      end
    end
  end

  def resolve(_path, _opts), do: {:error, "path must be a string"}

  @doc """
  Validates glob-style patterns used by file tools.
  """
  def validate_pattern(pattern) when is_binary(pattern) do
    with :ok <- reject_absolute(pattern),
         :ok <- reject_traversal(pattern) do
      :ok
    end
  end

  def validate_pattern(_pattern), do: {:error, "pattern must be a string"}

  @doc """
  Formats a path safety error consistently for tool responses.
  """
  def error(reason), do: "Error: #{reason}"

  def workspace_root do
    File.cwd!() |> Path.expand()
  end

  defp reject_absolute(path) do
    if Path.type(path) == :absolute do
      {:error, "absolute paths are not allowed: #{path}"}
    else
      :ok
    end
  end

  defp reject_traversal(path) do
    if ".." in Path.split(path) do
      {:error, "path traversal is not allowed: #{path}"}
    else
      :ok
    end
  end

  defp ensure_inside_workspace(path, root) do
    if inside?(path, root) do
      :ok
    else
      {:error, "path outside workspace: #{path}"}
    end
  end

  defp ensure_symlinks_inside(path, root, allow_missing) do
    path_to_check =
      if allow_missing do
        nearest_existing_parent(path)
      else
        path
      end

    check_symlink_components(path_to_check, root, path)
  end

  defp check_symlink_components(path, root, original_path) do
    root_parts = Path.split(root)
    relative_parts = path |> Path.relative_to(root) |> Path.split()

    root_parts
    |> Enum.concat(relative_parts)
    |> symlink_prefixes()
    |> Enum.reduce_while(:ok, fn prefix, :ok ->
      case File.lstat(prefix) do
        {:ok, %File.Stat{type: :symlink}} ->
          with {:ok, link_target} <- File.read_link(prefix),
               target_path <- resolve_link_target(prefix, link_target),
               :ok <- ensure_inside_workspace(target_path, root) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, _stat} ->
          {:cont, :ok}

        {:error, :enoent} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "cannot resolve path #{original_path}: #{reason}"}}
      end
    end)
  end

  defp symlink_prefixes(parts) do
    parts
    |> Enum.reduce([], fn part, prefixes ->
      next =
        case prefixes do
          [] -> part
          _ -> Path.join(List.last(prefixes), part)
        end

      prefixes ++ [next]
    end)
  end

  defp resolve_link_target(prefix, target) do
    if Path.type(target) == :absolute do
      Path.expand(target)
    else
      prefix |> Path.dirname() |> Path.join(target) |> Path.expand()
    end
  end

  defp nearest_existing_parent(path) do
    cond do
      File.exists?(path) ->
        path

      path == Path.dirname(path) ->
        path

      true ->
        nearest_existing_parent(Path.dirname(path))
    end
  end

  defp inside?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  @default_ignored MapSet.new([
                     ".git",
                     "_build",
                     "deps",
                     "node_modules",
                     ".venv",
                     "venv",
                     "__pycache__",
                     ".elixir_ls",
                     ".DS_Store"
                   ])

  @doc """
  Gets all gitignore ignore patterns for the given directory and the workspace root.
  """
  def gitignores_for_path(path) do
    root = workspace_root()
    ignores = get_ignores_from_dir(root)

    ignores =
      if path != root do
        MapSet.union(ignores, get_ignores_from_dir(path))
      else
        ignores
      end

    MapSet.union(ignores, @default_ignored)
  end

  @doc """
  Checks if a file is ignored based on the provided ignore patterns relative to a directory.
  """
  def ignored?(file, path, ignored_patterns) do
    rel_path = Path.relative_to(file, path)
    components = Path.split(rel_path)

    # First do a fast exact match of any individual component
    if Enum.any?(components, &MapSet.member?(ignored_patterns, &1)) do
      true
    else
      # Otherwise check wildcard patterns and full path matching
      Enum.any?(ignored_patterns, fn pattern ->
        match_pattern?(rel_path, components, pattern)
      end)
    end
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
