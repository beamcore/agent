defmodule Beamcore.Agent.Tools.Patch do
  @moduledoc """
  Tool to apply a unified diff patch to a file.
  """
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
    patch_content = Map.fetch!(params, "patch_content")
    workdir = Map.get(params, "workdir", File.cwd!())

    expanded_workdir = Path.expand(workdir)

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
  end
end
