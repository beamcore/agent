defmodule Beamcore.Agent.Tools.Edit do
  @moduledoc """
  Tool to replace exact string in a file.
  """
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Replace an exact, unique old string with a new string in a specified file.
  The old string must match exactly one occurrence in the file to avoid ambiguity.
  Use this for editing precise single blocks or lines of code in existing files.
  """

  def name, do: "edit"

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
              description: "The workspace-relative path to the file to modify."
            },
            old_string: %{
              type: "string",
              description: "The exact literal text to replace."
            },
            new_string: %{
              type: "string",
              description: "The exact literal text to replace old_string with."
            }
          },
          required: ["path", "old_string", "new_string"]
        }
      }
    }
  end

  def execute(params) do
    path = Map.fetch!(params, "path")
    old_string = Map.fetch!(params, "old_string")
    new_string = Map.fetch!(params, "new_string")

    with {:ok, expanded_path} <- PathSafety.resolve(path) do
      case File.read(expanded_path) do
        {:ok, content} ->
          if String.contains?(content, old_string) do
            parts = String.split(content, old_string)
            count = length(parts) - 1

            if count > 1 do
              "Error: old_string is ambiguous. It occurs #{count} times in the file."
            else
              new_content = String.replace(content, old_string, new_string)

              case File.write(expanded_path, new_content) do
                :ok -> "Successfully updated #{expanded_path}"
                {:error, reason} -> "Error writing file #{expanded_path}: #{reason}"
              end
            end
          else
            lines = String.split(content, "\n")

            numbered =
              lines
              |> Enum.with_index(1)
              |> Enum.map(fn {line, num} -> "#{num}: #{line}" end)

            preview = numbered |> Enum.take(30) |> Enum.join("\n")

            old_line = String.split(old_string, "\n") |> hd()

            similar =
              lines
              |> Enum.with_index(1)
              |> Enum.filter(fn {line, _num} ->
                String.jaro_distance(String.trim(line), String.trim(old_line)) > 0.7
              end)
              |> Enum.take(5)
              |> Enum.map(fn {line, num} -> "  #{num}: #{line}" end)
              |> Enum.join("\n")

            hint = if similar != "", do: "\n\nSimilar lines found:\n#{similar}", else: ""

            "Error: old_string not found in file.\n\nFile preview (first 30 lines):\n#{preview}#{hint}"
          end

        {:error, reason} ->
          "Error reading file #{expanded_path}: #{reason}"
      end
    else
      {:error, reason} ->
        PathSafety.error(reason)
    end
  end
end
