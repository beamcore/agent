defmodule Beamcore.Agent.Tools.Write do
  @moduledoc """
  Tool to write content to a file.
  """
  @description """
  Write full file content to the specified absolute path on the local filesystem.
  Automatically creates parent directories if needed, and overwrites existing files.
  Best for creating new source code files or replacing complete contents of a file.
  """

  def name, do: "write"

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
              description: "The absolute path to the file to write"
            },
            content: %{
              type: "string",
              description: "The content to write to the file"
            }
          },
          required: ["filePath", "content"]
        }
      }
    }
  end

  def execute(params) do
    file_path = Map.fetch!(params, "filePath")
    content = Map.fetch!(params, "content")

    expanded_path = Path.expand(file_path)
    expanded_path |> Path.dirname() |> File.mkdir_p!()

    case File.write(expanded_path, content) do
      :ok -> "Successfully wrote to #{expanded_path}"
      {:error, reason} -> "Error writing file #{expanded_path}: #{reason}"
    end
  end
end
