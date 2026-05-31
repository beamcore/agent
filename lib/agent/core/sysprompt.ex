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
    "web_get: network fetch and system execution tasks.",
    "task: start sub agents to do parallel work.",
    "image_generation: Mistral image_generation agent tool.",
    "memory: persistent memory service to remember, recall, list, and forget scoped knowledge."
  ]

  @doc """
  Generates the full system prompt.
  """
  def generate(project_nature \\ :unknown) do
    formatted_tools = Enum.map_join(@default_tools, "\n- ", & &1)

    """
    You are Beamcore.Agent: a general-purpose coding agent.

    Your function is to follow the user instruction.

    Workspace: .
    #{project_nature_details(project_nature)}

    Available tools:
    - #{formatted_tools}

    #{memory_guidelines_and_index()}

    Response style: concise, factual, robotic professional.
    """
  end

  @doc """
  Returns the shared memory guidelines and accumulated memory index.
  """
  def memory_guidelines_and_index do
    """
    Memory Guidelines:
    - You are highly encouraged to use the `memory` tool to `recall` prior workspace insights, architecture notes, decisions, or user preferences on startup.
    - Save new lessons, errors/fixes, and architectural choices using `memory` with descriptive, snake_case keys (e.g. `user_preferences`, `loop_fix_2026`).
    - **Memory Updates (Upserting)**: The `remember` action automatically overwrites/updates any existing key. If you discover that a recalled memory is stale, you MUST run `remember` on the same key to overwrite it with the updated, accurate information.
    #{memory_index_details()}
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

  defp memory_index_details do
    case Beamcore.Agent.Workspace.current_context() do
      nil ->
        ""

      {org, repo} ->
        categories = [:repo_map, :patterns, :decisions, :errors, :context]

        index_lines =
          Enum.map(categories, fn type ->
            keys =
              Beamcore.Memory.list(org, repo, type)
              |> Enum.map(fn {k, _v} -> k end)

            if keys == [] do
              nil
            else
              "  - #{type}: #{inspect(keys)}"
            end
          end)
          |> Enum.reject(&is_nil/1)

        if index_lines == [] do
          ""
        else
          """

          Accumulated Repository Memory Index (Use the `memory` tool to `recall` these keys):
          #{Enum.join(index_lines, "\n")}
          """
        end
    end
  end
end
