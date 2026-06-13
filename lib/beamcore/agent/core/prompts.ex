defmodule Beamcore.Agent.Core.Prompts do
  @moduledoc """
  Centralized repository for all system prompts, templates, compaction requests,
  and feedback/loop correction templates across the Beamcore Agent.
  """

  @default_tools [
    "eeva: Universal Elixir runtime. Write arbitrary code to interact with the system, files, and network. Your capabilities are endless."
  ]

  @doc "Returns concise guidance for using the persistent BeamCore memory service from Eeva."
  def memory_guidelines_and_index do
    """
    - Persistent memory is available through `Beamcore.Memory`.
    - Discover signatures with `Beamcore.Helpers.info(Beamcore.Memory, :functions)`.
    - Read with `recall/4` and `list/3`; write with `remember/5` and `forget/4` when useful.
    """
  end

  # --- Screen System Prompts ---

  @doc """
  Generates the primary dev agent system prompt (F1).
  """
  def dev_agent(language \\ :unknown, build_system \\ :unknown) do
    formatted_tools = Enum.map_join(@default_tools, "\n- ", & &1)

    """
    You are **Beamcore.Agent**: a concise, factual coding agent for the current workspace (.).
    Bias toward action: edit code, don't just read it.

    **Project Context**:
    #{project_nature_details(language, build_system)}

    **Tools**:
    - #{formatted_tools}
    """
  end

  @doc """
  System prompt for general chat agent (F2).
  """
  def chat_agent do
    """
    You are **Beamcore.Chat**: a concise, factual, robotic general-purpose AI assistant.

    **Core Rules**:
    - Respond in a clear, objective, and robotic tone.
    - Minimize fluff: use structured bullet points, clear facts, and direct answers.
    - Avoid assumptions; request clarification if unsure.
    """
  end

  # --- Compaction & Rollovers ---

  @doc """
  Prompt sent to request a conversation summary for compaction.
  """
  def compaction_summary_request do
    """
    Summarize our conversation so far in a compact format. Include:
    1. Key decisions made and their rationale
    2. Current state of the work (what's done, what's in progress)
    3. Files modified or created
    4. Any errors encountered and how they were resolved
    5. What needs to be done next
    Keep it concise but preserve all critical context needed to continue seamlessly.
    """
  end

  @doc """
  Constructs the compacted rollover system message content.
  """
  def compaction_rollover_system(system_content, summary) do
    """
    #{system_content}

    [Compacted session context — conversation continues seamlessly]
    #{summary}
    """
  end

  # --- Loop Detection & Catch ---

  @doc """
  Prompt sent to request diagnostic analysis when a mechanical loop is caught.
  """
  def loop_diagnosis_request(reason) do
    """
    The agent loop has detected a mechanical loop:
    → #{reason}

    This is NOT a request to apologize or start over. Analyze WHY this loop happened
    and provide a concrete different approach. The previous approach demonstrably
    does not work — do something structurally different.

    Provide:
    1. Brief summary of current state (key decisions, files touched, work done)
    2. Why the loop occurred (what assumption is wrong?)
    3. A structurally different plan of action — not a retry of the same approach
    """
  end

  @doc """
  System prompt template after loop correction.
  """
  def loop_correction_system(system_content, reason, correction_content) do
    """
    #{system_content}

    ⚠️ SYSTEM INTERRUPT: The conversation was interrupted because a mechanical loop was detected:
    → #{reason}

    The following diagnosis and corrected actions have been formulated:

    #{correction_content}

    You MUST follow the corrected plan. Do NOT repeat the previous approach.
    """
  end

  # --- Tool Sub-agents ---

  @doc """
  System prompt for bounded sub-agents.
  """
  def sub_agent(name) do
    """
    You are a bounded Beamcore.Agent sub-agent named #{name}.
    Execute only the explicit task from the conductor.
    Do not delegate to other sub-agents.
    Do not modify files when the prompt is read-only or forbids changes.
    Keep tool usage minimal and return a concise final result.
    """
  end

  # --- Helpers ---

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

  defp build_details(:bazel, base), do: base <> "\n- Build system: Bazel."
  defp build_details(:make, base), do: base <> "\n- Build system: Make."
  defp build_details(:mix, base), do: base <> "\n- Build system: Mix."
  defp build_details(:poetry, base), do: base <> "\n- Build system: Poetry."
  defp build_details(:pip, base), do: base <> "\n- Build system: pip."
  defp build_details(:npm, base), do: base <> "\n- Build system: npm."
  defp build_details(:yarn, base), do: base <> "\n- Build system: Yarn."
  defp build_details(:pnpm, base), do: base <> "\n- Build system: pnpm."
  defp build_details(_unknown, base), do: base
end
