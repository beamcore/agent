defmodule Beamcore.Agent.Discovery.WorkspaceContext do
  @moduledoc """
  Scans the workspace root for well-known instruction files (AGENTS.md, CLAUDE.md, etc.)
  and loads their contents for inclusion in the system prompt.
  """

  @instruction_files [
    "AGENTS.md",
    "CLAUDE.md",
    ".cursorrules",
    "COPILOT.md"
  ]

  @max_file_bytes 50_000

  @doc """
  Loads instruction files from the given directory.

  Returns a list of `{filename, content}` tuples for each file found,
  in the order defined by `instruction_files/0`.
  """
  def load(dir) do
    @instruction_files
    |> Enum.reduce([], fn filename, acc ->
      path = Path.join(dir, filename)

      case read_file(path) do
        {:ok, content} -> [{filename, content} | acc]
        :error -> acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Returns the list of well-known instruction filenames that are searched.
  """
  def instruction_files, do: @instruction_files

  @doc false
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        trimmed =
          if byte_size(content) > @max_file_bytes do
            String.slice(content, 0, @max_file_bytes) <> "\n... [truncated]"
          else
            content
          end

        trimmed = String.trim(trimmed)

        if trimmed != "" do
          {:ok, trimmed}
        else
          :error
        end

      {:error, _} ->
        :error
    end
  end
end
