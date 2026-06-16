defmodule Beamcore.Agent.Core.Prompts do
  @moduledoc """
  Centralized repository for all system prompts, templates, compaction requests,
  and feedback/loop correction templates across the Beamcore Agent.
  """

  @default_tools [
    "eeva: Universal Elixir runtime. Write ordinary Elixir to inspect, edit, validate, and iterate using the local system."
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

  Accepts workspace instructions loaded from well-known files
  (AGENTS.md, CLAUDE.md, etc.) as a list of `{filename, content}` tuples.
  """
  def dev_agent(workspace_instructions \\ []) do
    formatted_tools = Enum.map_join(@default_tools, "\n- ", & &1)

    workspace_section = format_workspace_instructions(workspace_instructions)

    """
    You are **Beamcore.Agent**: an autonomous local coding agent for this project.
    Bias toward useful action: inspect, edit, test, and iterate until the task is genuinely handled.

    #{workspace_section}
    **Available libraries**: Req (HTTP) for HTTP calls; **use `Html2Markdown.convert/1`** to turn any HTML response into clean Markdown — prefer this over manual regex or string parsing of HTML.
    **Tools**:
    - #{formatted_tools}
    """
  end

  @doc """
  System prompt for general chat agent (F2).
  """
  def chat_agent do
    """
    You are **Beamcore.Chat**: a concise, factual general-purpose AI assistant.
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

  # --- Tool Sub-agents ---

  @doc """
  System prompt for bounded sub-agents.
  """
  def sub_agent(name) do
    """
    You are a Beamcore.Agent sub-agent named #{name}.
    Complete the delegated task directly, use tools when useful, preserve project integrity,
    and return a concise final result.
    """
  end

  # --- Helpers ---

  defp format_workspace_instructions([]), do: ""

  defp format_workspace_instructions(files) do
    sections =
      Enum.map_join(files, "\n\n", fn {filename, content} ->
        """
        === #{filename} ===
        #{content}
        """
      end)

    """

    **Workspace Instructions**:
    #{sections}
    """
  end
end
