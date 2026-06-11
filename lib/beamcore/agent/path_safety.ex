defmodule Beamcore.Agent.PathSafety do
  @moduledoc """
  Resolves user-provided tool paths inside the current workspace.
  """

  # Stop Dialyzer from deconstructing MapSet's internal structural representation
  @dialyzer {:no_opaque, gitignores_for_path: 1, get_ignores_from_dir: 1}

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
         :ok <- reject_traversal(cleaned_path),
         :ok <- reject_internal_store(cleaned_path) do
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
  @spec validate_pattern(String.t()) :: :ok | {:error, String.t()}
  def validate_pattern(pattern) when is_binary(pattern) do
    with :ok <- reject_absolute(pattern),
         :ok <- reject_traversal(pattern),
         :ok <- reject_internal_store(pattern) do
      :ok
    end
  end

  def validate_pattern(_pattern), do: {:error, "pattern must be a string"}

  @doc """
  Formats a path safety error consistently for tool responses.
  """
  def error(reason), do: "Error: #{reason}"

  def workspace_root do
    configured = Process.get(:workspace_root) || Application.get_env(:agent, :workspace_root)

    cond do
      is_binary(configured) and File.dir?(configured) ->
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
      is_binary(initial) and File.dir?(initial) -> canonical_path(initial)
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
    do: Application.put_env(:agent, :workspace_root, root)

  def canonical_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      case System.cmd("pwd", ["-P"], cd: expanded, stderr_to_stdout: true) do
        {resolved, 0} -> String.trim(resolved)
        _ -> expanded
      end
    else
      expanded
    end
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

  defp reject_internal_store(path) do
    normalized = internal_normalize(path)

    if internal_store_path?(normalized) do
      {:error, "BeamCore internal snapshot, recovery, and memory paths are not available to agent tools"}
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
          with {:ok, link_target} <- File.read_link(prefix) do
            target_path = resolve_link_target(prefix, link_target)

            with :ok <- ensure_inside_workspace(target_path, root),
                 :ok <- reject_internal_symlink_target(target_path, root) do
              {:cont, :ok}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
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

  defp reject_internal_symlink_target(target_path, root) do
    relative = target_path |> Path.relative_to(root) |> internal_normalize()

    cond do
      internal_store_path?(relative) ->
        {:error, "symlink target points to BeamCore internal snapshot, recovery, or memory storage"}

      journal_excluded_root?(relative) ->
        {:error, "symlink target points to workspace metadata excluded from rollback"}

      true ->
        :ok
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

  defp journal_excluded_root?(normalized) do
    root = normalized |> String.split("/", parts: 2) |> hd()
    root in [".git", ".elixir_ls", "_build", "deps", "node_modules"]
  end

  defp internal_store_path?(normalized) do
    String.starts_with?(normalized, ".beamcore/snapshots") or
      String.starts_with?(normalized, ".beamcore/recovery") or
      String.starts_with?(normalized, ".beamcore/memory")
  end

  defp internal_normalize(path) do
    path
    |> Path.split()
    |> Enum.join("/")
    |> String.downcase()
  end

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
