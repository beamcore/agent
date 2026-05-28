defmodule Beamcore.Agent.Tools.Patch do
  @moduledoc """
  Tool to apply a unified diff patch to a file.
  """
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Apply a standard unified diff patch to target files within a specified workspace directory.
  The patch content must be a valid, well-formed unified diff structure.
  Use this tool to apply programmatic, complex patches or multi-file edits cleanly.
  """

  def name, do: "patch"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            patch_content: %{
              type: "string",
              description: "The unified diff content to apply."
            },
            workdir: %{
              type: "string",
              description: "The directory to apply the patch in. Defaults to current directory."
            }
          },
          required: ["patch_content"]
        }
      }
    }
  end

  def execute(params) do
    patch_content = Map.fetch!(params, "patch_content") |> sanitize_obfuscated_emails()
    workdir = Map.get(params, "workdir", ".")

    with :ok <- validate_patch_paths(patch_content),
         :ok <- validate_project_policy_paths(patch_content),
         {:ok, expanded_workdir} <- PathSafety.resolve(workdir) do
      patch_file =
        Path.join(System.tmp_dir!(), "agent_patch_#{System.unique_integer([:positive])}.diff")

      File.write!(patch_file, patch_content)

      try do
        case System.cmd("patch", ["-p1", "-i", patch_file],
               cd: expanded_workdir,
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            "Patch applied successfully:\n#{output}"

          {output, _} ->
            "Error applying patch:\n#{output}"
        end
      after
        File.rm(patch_file)
      end
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp validate_patch_paths(patch_content) do
    patch_content
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ")))
    |> Enum.map(&patch_path/1)
    |> Enum.reject(&(&1 in [nil, "/dev/null"]))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case path |> strip_patch_prefix() |> PathSafety.validate_pattern() do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_project_policy_paths(patch_content) do
    patch_content
    |> patch_paths()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case ProjectPolicy.allowed_write_path?(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp patch_paths(patch_content) do
    patch_content
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ")))
    |> Enum.map(&patch_path/1)
    |> Enum.reject(&(&1 in [nil, "/dev/null"]))
    |> Enum.map(&strip_patch_prefix/1)
    |> Enum.uniq()
  end

  defp patch_path(line) do
    line
    |> String.split(~r/\s+/, parts: 3, trim: true)
    |> Enum.at(1)
  end

  defp strip_patch_prefix("a/" <> path), do: path
  defp strip_patch_prefix("b/" <> path), do: path
  defp strip_patch_prefix(path), do: path

  defp sanitize_obfuscated_emails(content) when is_binary(content) do
    String.replace(content, ~r/\[email[\s\x{00A0}]*protected\]/iu, "$@")
  end
end
