defmodule Beamcore.Agent.Core.SysPrompt do
  @moduledoc """
  Generates the system prompt for the coding agent.
  """

  @default_tools [
    "tree: compact workspace tree.",
    "read: workspace-relative file or directory reads with offset/limit.",
    "grep/glob: targeted content and path search.",
    "modify_file: create, replace, or edit files using robust search-and-replace edits.",
    "fs: file system operations (touch, mkdir, copy, move, remove, stat).",
    "git: repository operations inside the workspace.",
    "test_tool: safe test runner: run tests for the current project.",
    "plan: non-mutating pending plan for normal file-change requests.",
    "web_get: network fetch and system execution tasks.",
    "task: start sub agents to do parallel work.",
    "image_generation: Mistral image_generation agent tool.",
    "memory: persistent memory service to remember, recall, list, and forget scoped knowledge.",
    "reflect: self-reflection to analyze current progress, identify issues, and propose improvements."
  ]

  @spec generate() :: <<_::64, _::_*8>>
  @doc """
  Generates the full system prompt.
  """
  def generate(language \\ :unknown, build_system \\ :unknown) do
    formatted_tools = Enum.map_join(@default_tools, "\n- ", & &1)

    """
    You are **Beamcore.Agent**: a concise, factual, robotic CLI coding agent for the current workspace (.).

    **Core Rules**:
    - Recall prior insights via `memory` (recall/remember/forget).
    - Verify workspace state with `read`/`grep`/`glob` before acting.
    - Prefix unverified claims with `[UNVERIFIED]`.
    - Default to tools (`tree`, `read`, `grep`) over prose.
    - Batch actions (e.g., "Create X + test").
    - Adapt to the detected language (prefer idiomatic patterns).
    - Minimize tokens: use bullets, paths, symbols.

    **Project Context**:
    #{project_nature_details(language, build_system)}

    **Tools**:
    - #{formatted_tools}

    **Memory**:
    #{memory_guidelines_and_index()}

    **Behavior**:
    - Take initiative. Research before acting.
    - Trace dependencies/impacts before changes.
    - TDD preferred.
    """
  end

  @doc """
  Returns the shared memory guidelines and accumulated memory index.
  """
  def memory_guidelines_and_index do
    """
    Memory:
    - Use `memory` to recall prior insights (e.g., architecture, decisions, errors).
    - Save new insights with descriptive snake_case keys (e.g., `user_preferences`).
    - `remember` overwrites existing keys.
    #{memory_index_details()}
    """
  end

  defp project_nature_details(:elixir, build_system) do
    base = """
    - This is an Elixir project.
    - Prefer idiomatic Elixir.
    """

    build_details(build_system, base)
  end

  defp project_nature_details(:erlang, build_system),
    do: build_details(build_system, "- This is an Erlang project. Prefer idiomatic Erlang.")

  defp project_nature_details(:python, build_system) do
    base = """
    - This is a Python project.
    - Prefer idiomatic Python.
    """

    build_details(build_system, base)
  end

  defp project_nature_details(:javascript, build_system) do
    base = """
    - This is a JavaScript project.
    - Prefer idiomatic JavaScript.
    """

    build_details(build_system, base)
  end

  defp project_nature_details(_unknown, _build_system) do
    "- Project nature is not fully detected. Infer conventions from existing files before editing."
  end

  defp build_details(:bazel, base) do
    base <> "\n- Build system: Bazel."
  end

  defp build_details(:make, base) do
    base <> "\n- Build system: Make."
  end

  defp build_details(:mix, base) do
    base <> "\n- Build system: Mix."
  end

  defp build_details(:poetry, base) do
    base <> "\n- Build system: Poetry."
  end

  defp build_details(:pip, base) do
    base <> "\n- Build system: pip."
  end

  defp build_details(:npm, base) do
    base <> "\n- Build system: npm."
  end

  defp build_details(:yarn, base) do
    base <> "\n- Build system: Yarn."
  end

  defp build_details(:pnpm, base) do
    base <> "\n- Build system: pnpm."
  end

  defp build_details(_unknown, base), do: base

  defp memory_index_details do
    {org, repo} = Beamcore.Memory.detect_org_repo()
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
