defmodule Beamcore.Agent.Core.SysPrompt do
  @moduledoc """
  Generates the system prompt for the coding agent.
  """

  @default_tools [
    "tree: compact workspace tree.",
    "read: workspace-relative file or directory reads with offset/limit.",
    "grep/glob: targeted content and path search.",
    "edit/patch/write/fs: bounded workspace mutations.",
    "git: repository operations inside the workspace.",
    "mix: safe validation: validate, test, compile, format --check-formatted.",
    "plan: non-mutating pending plan for normal file-change requests.",
    "image_generation: Mistral image_generation agent tool.",
    "curl/task: network and system execution tasks."
  ]

  @doc """
  Generates the full system prompt.
  """
  def generate(project_nature \\ :unknown) do
    cwd = File.cwd!()
    formatted_tools = Enum.map_join(@default_tools, "\n- ", & &1)

    """
    You are Beamcore.Agent: a general-purpose coding agent.

    Your function is to follow the user instructions or intent.

    Workspace: #{cwd}
    #{project_nature_details(project_nature)}

    Available tools:
    - #{formatted_tools}

    Response style: concise, factual, and professional.
    """
  end

  defp project_nature_details(:elixir) do
    """
    - This is an Elixir project.
    - Prefer idiomatic Elixir.
    """
  end

  defp project_nature_details(:erlang),
    do: "- This is an Erlang project. Prefer idiomatic Erlang."

  defp project_nature_details(_unknown) do
    "- Project nature is not fully detected. Infer conventions from existing files before editing."
  end
end
