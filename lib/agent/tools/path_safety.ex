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

    with :ok <- reject_absolute(path),
         :ok <- reject_traversal(path) do
      root = workspace_root()
      candidate = Path.expand(path, root)

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
end
