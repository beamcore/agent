defmodule Beamcore.Agent.Tools.Write do
  @moduledoc """
  Tool to write content to a file.
  """
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Write full file content to the specified workspace-relative path.
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
            filePath: %{type: "string", description: "The workspace-relative path to write"},
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
    file_path = fetch_path!(params)
    content = Map.fetch!(params, "content")

    with {:ok, expanded_path} <- PathSafety.resolve(file_path, allow_missing: true) do
      expanded_path |> Path.dirname() |> File.mkdir_p!()

      case File.write(expanded_path, content) do
        :ok -> "Successfully wrote to #{expanded_path}"
        {:error, reason} -> "Error writing file #{expanded_path}: #{reason}"
      end
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp fetch_path!(params) do
    Map.get(params, "filePath") || Map.get(params, "path") || raise(KeyError, key: "filePath")
  end
end
