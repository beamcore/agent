defmodule Beamcore.Agent.Tools.Read do
  @moduledoc """
  Tool to read files or directories from the local filesystem.
  """

  @default_limit 50
  @max_line_length 200

  @description """
  Read a file or list contents of a directory on the local filesystem.
  Returns line-numbered contents up to a configurable limit from the given start offset.
  Essential for reviewing source files, inspecting structure, and viewing directories.
  """

  def name, do: "read"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            filePath: %{
              type: "string",
              description: "The absolute path to the file or directory to read"
            },
            offset: %{
              type: "integer",
              description: "The line number to start reading from (1-indexed)"
            },
            limit: %{
              type: "integer",
              description: "The maximum number of lines to read (defaults to 50)"
            }
          },
          required: ["filePath"]
        }
      }
    }
  end

  def execute(params) do
    file_path = Map.fetch!(params, "filePath")
    offset = Map.get(params, "offset", 1)
    limit = Map.get(params, "limit", @default_limit)

    expanded_path = Path.expand(file_path)

    case File.stat(expanded_path) do
      {:ok, %File.Stat{type: :directory}} ->
        read_directory(expanded_path, offset, limit)

      {:ok, %File.Stat{type: :regular}} ->
        read_file(expanded_path, offset, limit)

      {:ok, _} ->
        "Error: Path is not a regular file or directory: #{expanded_path}"

      {:error, :enoent} ->
        suggest_files(expanded_path)

      {:error, reason} ->
        "Error reading path #{expanded_path}: #{reason}"
    end
  end

  defp read_directory(path, offset, limit) do
    case File.ls(path) do
      {:ok, files} ->
        # Sort files alphabetically
        sorted_files = Enum.sort(files)

        # Add trailing slash for directories
        formatted_files =
          Enum.map(sorted_files, fn file ->
            full_path = Path.join(path, file)

            case File.stat(full_path) do
              {:ok, %File.Stat{type: :directory}} -> "#{file}/"
              _ -> file
            end
          end)

        start_idx = max(0, offset - 1)
        sliced_files = Enum.slice(formatted_files, start_idx, limit)
        total_entries = length(formatted_files)
        shown_count = length(sliced_files)
        left_count = total_entries - (start_idx + shown_count)

        output =
          [
            "<path>#{path}</path>",
            "<type>directory</type>",
            "<entries>"
          ] ++ sliced_files

        output =
          if left_count > 0 do
            output ++
              [
                "\n(Showing #{shown_count} of #{total_entries} entries. #{left_count} entries left. Use 'offset' parameter to read beyond entry #{offset + shown_count})"
              ]
          else
            output ++ ["\n(#{total_entries} entries)"]
          end

        (output ++ ["</entries>"])
        |> Enum.join("\n")

      {:error, reason} ->
        "Error reading directory #{path}: #{reason}"
    end
  end

  defp read_file(path, offset, limit) do
    start_idx = max(0, offset - 1)

    try do
      total_lines = File.stream!(path) |> Enum.count()

      lines_with_index =
        File.stream!(path)
        |> Stream.with_index(1)
        |> Stream.drop(start_idx)
        |> Stream.take(limit)
        |> Enum.to_list()

      formatted_lines =
        Enum.map(lines_with_index, fn {line, idx} ->
          clean_line =
            String.trim_trailing(line, "\n")
            |> String.trim_trailing("\r")

          truncated_line =
            if String.length(clean_line) > @max_line_length do
              String.slice(clean_line, 0, @max_line_length) <>
                "... (line truncated to #{@max_line_length} chars)"
            else
              clean_line
            end

          "#{idx}: #{truncated_line}"
        end)

      output =
        [
          "<path>#{path}</path>",
          "<type>file</type>",
          "<content>"
        ] ++ formatted_lines

      shown_count = length(formatted_lines)
      left_count = max(0, total_lines - (start_idx + shown_count))
      last = offset + shown_count - 1
      next = last + 1

      output =
        if left_count > 0 do
          output ++
            [
              "\n(Showing lines #{offset}-#{last}. #{left_count} lines left. Use offset=#{next} to continue.)"
            ]
        else
          output ++ ["\n(End of file)"]
        end

      (output ++ ["</content>"])
      |> Enum.join("\n")
    rescue
      e ->
        "Error reading file #{path}: #{Exception.message(e)}"
    end
  end

  defp suggest_files(path) do
    dir = Path.dirname(path)
    base = Path.basename(path) |> String.downcase()

    suggestions =
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(fn f ->
            String.contains?(String.downcase(f), base) or
              String.contains?(base, String.downcase(f))
          end)
          |> Enum.take(3)
          |> Enum.map(&Path.join(dir, &1))

        _ ->
          []
      end

    if suggestions != [] do
      "Error: File not found: #{path}\n\nDid you mean one of these?\n" <>
        Enum.join(suggestions, "\n")
    else
      "Error: File not found: #{path}"
    end
  end
end
