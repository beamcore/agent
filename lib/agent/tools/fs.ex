defmodule Beamcore.Agent.Tools.Fs do
  @moduledoc """
  Tool to perform filesystem operations.

  This tool provides a safe alternative to shell commands for common filesystem operations.
  Instead of using shell commands, agents should use this tool for filesystem operations.
  """

  @description """
  Perform local filesystem operations: move, copy, remove, touch, mkdir, stat, and exist.
  All paths are expanded relative to the current active working directory.
  A safe programmatic alternative to using shell commands for manipulating files.
  """

  @doc """
  Name of the tool.
  """
  def name, do: "fs"

  @doc """
  Get the tool specification for API calls.
  """
  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            operation: %{
              type: "string",
              enum: ["move", "copy", "remove", "touch", "stat", "exist", "mkdir"],
              description: "The filesystem operation to perform"
            },
            path: %{
              type: "string",
              description: "The source path for the operation"
            },
            target: %{
              type: "string",
              description: "The target path (for move, copy operations)"
            },
            recursive: %{
              type: "boolean",
              description: "Whether to operate recursively (for copy, remove on directories)",
              default: false
            },
            force: %{
              type: "boolean",
              description:
                "Whether to force the operation (overwrite for copy, ignore errors for remove)",
              default: false
            }
          },
          required: ["operation", "path"]
        }
      }
    }
  end

  @doc """
  Execute the filesystem operation.
  """
  def execute(params) do
    operation = Map.fetch!(params, "operation")
    path = Map.fetch!(params, "path")
    target = Map.get(params, "target")
    recursive = Map.get(params, "recursive", false)
    force = Map.get(params, "force", false)

    expanded_path = Path.expand(path)
    expanded_target = if target, do: Path.expand(target), else: nil

    case operation do
      "move" ->
        move_file(expanded_path, expanded_target, force)

      "copy" ->
        copy_file(expanded_path, expanded_target, recursive, force)

      "remove" ->
        remove_path(expanded_path, recursive, force)

      "touch" ->
        touch_file(expanded_path)

      "stat" ->
        stat_path(expanded_path)

      "exist" ->
        check_exists(expanded_path)

      "mkdir" ->
        mkdir_path(expanded_path)

      _ ->
        "Error: Unknown operation '#{operation}'. Valid operations: move, copy, remove, touch, stat, exist, mkdir"
    end
  end

  # Move operation
  defp move_file(source, target, force) do
    cond do
      !File.exists?(source) ->
        "Error: Source path does not exist: #{source}"

      File.exists?(target) && !force ->
        "Error: Target path already exists: #{target}. Use force=true to overwrite."

      true ->
        case File.rename(source, target) do
          :ok -> "Successfully moved '#{source}' to '#{target}'"
          {:error, reason} -> "Error moving '#{source}' to '#{target}': #{reason}"
        end
    end
  end

  # Copy operation
  defp copy_file(source, target, _recursive, force) do
    cond do
      !File.exists?(source) ->
        "Error: Source path does not exist: #{source}"

      File.exists?(target) && !force ->
        "Error: Target path already exists: #{target}. Use force=true to overwrite."

      true ->
        case File.cp_r(source, target) do
          {:ok, _} -> "Successfully copied '#{source}' to '#{target}'"
          {:error, reason} -> "Error copying '#{source}' to '#{target}': #{reason}"
        end
    end
  end

  # Remove operation
  defp remove_path(path, recursive, force) do
    cond do
      !File.exists?(path) ->
        if force do
          "Path does not exist, but force=true so no error: #{path}"
        else
          "Error: Path does not exist: #{path}"
        end

      File.dir?(path) && !recursive ->
        "Error: Cannot remove directory '#{path}' without recursive=true"

      true ->
        if File.dir?(path) do
          case File.rm_rf(path) do
            {:ok, _} -> "Successfully removed: #{path}"
            {:error, reason, _} -> "Error removing '#{path}': #{reason}"
          end
        else
          case File.rm(path) do
            :ok -> "Successfully removed: #{path}"
            {:error, reason} -> "Error removing '#{path}': #{reason}"
          end
        end
    end
  end

  # Touch operation
  defp touch_file(path) do
    case File.touch(path) do
      :ok -> "Successfully touched: #{path}"
      {:error, reason} -> "Error touching '#{path}': #{reason}"
    end
  end

  # Stat operation
  defp stat_path(path) do
    case File.stat(path) do
      {:ok, stat} ->
        """
        Path: #{path}
        Type: #{file_type(stat.type)}
        Size: #{stat.size} bytes
        Access Time: #{format_time(stat.atime)}
        Modify Time: #{format_time(stat.mtime)}
        Change Time: #{format_time(stat.ctime)}
        Mode: #{Integer.to_string(stat.mode, 8)}
        Links: #{stat.links}
        UID: #{stat.uid}
        GID: #{stat.gid}
        """

      {:error, reason} ->
        "Error getting stat for '#{path}': #{reason}"
    end
  end

  # Exist operation
  defp check_exists(path) do
    if File.exists?(path) do
      "true"
    else
      "false"
    end
  end

  # Mkdir operation
  defp mkdir_path(path) do
    case File.mkdir_p(path) do
      :ok -> "Successfully created directory: #{path}"
      {:error, reason} -> "Error creating directory #{path}: #{reason}"
    end
  end

  # Helper functions
  def file_type(:regular), do: "regular file"
  def file_type(:directory), do: "directory"
  def file_type(:symlink), do: "symbolic link"
  def file_type(:character), do: "character device"
  def file_type(:block), do: "block device"
  def file_type(:fifo), do: "FIFO (named pipe)"
  def file_type(:socket), do: "socket"
  def file_type(_), do: "unknown"

  defp format_time({{year, month, day}, {hour, min, sec}}) do
    "#{year}-#{String.pad_leading(to_string(month), 2, "0")}-#{String.pad_leading(to_string(day), 2, "0")} " <>
      "#{String.pad_leading(to_string(hour), 2, "0")}:#{String.pad_leading(to_string(min), 2, "0")}:#{String.pad_leading(to_string(sec), 2, "0")}"
  end
end
