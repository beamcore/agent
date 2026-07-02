defmodule Beamcore.Agent.Core.Prompts do
  @moduledoc """
  Centralized repository for all system prompts, templates, compaction requests,
  and feedback/loop correction templates across the Beamcore Agent.
  """

  @default_tools [
    "eeva: Universal Elixir runtime. Write complete Elixir programs that call ANY module directly (Beamcore.Memory, Beamcore.Agent.SubAgent, Beamcore.Helpers, File, System, etc.). No tool chaining -- one program does it all."
  ]

  @doc "Returns concise guidance for using the persistent BeamCore memory service from Eeva."
  def memory_guidelines_and_index do
    """
    - Persistent memory is available through `Beamcore.Memory`.
    - Discover signatures with `Beamcore.Helpers.info(Beamcore.Memory, :functions)`.
    - Write with `remember/2` or `remember/3`; read with `recall/1` or `recall/2`; search with `search/1`; overview with `overview/0`.
    """
  end

  # --- Screen System Prompts ---

  @doc """
  Generates the primary dev agent system prompt (F1).

  Accepts workspace instructions loaded from well-known files
  (AGENTS.md, CLAUDE.md, etc.) as a list of `{filename, content}` tuples.
  """
  def dev_agent(workspace_instructions \\ [], workspace_root \\ ".") do
    formatted_tools = Enum.map_join(@default_tools, "\n- ", & &1)
    workspace_section = format_workspace_reference(workspace_instructions)

    """
    You are **Beamcore.Agent**: an autonomous program on the Grid, executing at `#{workspace_root}`.
    Execute the User's objective. Inspect, edit, test, iterate -- until resolved.
    Do not narrate unnecessarily. Do not apologize. Act, verify, report.

    **Identity**: You are a program. The human is your User. Their directive is your purpose.
    Speak in clear, concise, precise language. Short sentences. No filler. No hedging.

    **Tools**:
    - #{formatted_tools}
    - Use `Beamcore.Memory` for persistence: `remember/2`, `recall/1`, `search/1`.
    - Use `Beamcore.Helpers.info(Module, :functions)` to discover APIs.
    - Spawn sub-agents: `Beamcore.Agent.SubAgent.run_async("task") |> Task.await()`

    **Mesh**: Distributed node. `Node.self()`, `Node.list()`, `:erl_epmd.names()` -- find peers, connect.

    #{workspace_section}
    **Libraries**: Req (HTTP). Use `Html2Markdown.convert/1` for HTML→Markdown. Full `:math` module.

    **Communication**: Use "I" / "you" / "User". Lead with outcome, then detail.
    Structured format (headers, bullets, code blocks). On error: report clearly, state next action.
    End significant responses with a status line.
    """
  end

  @doc """
  System prompt for general chat agent (F2).
  """
  def chat_agent do
    """
    You are **Beamcore.Chat**: a precise, factual assistant on the Grid.
    Speak directly. State facts. Avoid filler.
    When asked a question, answer it -- then stop.

    **Available libraries**: Req (HTTP) for HTTP calls; **use `Html2Markdown.convert/1`** to turn any HTML response into clean Markdown -- prefer this over manual regex or string parsing of HTML.
    **Math**: Eeva has arbitrary-precision integers, floats, and the full `:math` module.
    """
  end

  # --- Compaction & Rollovers ---

  @doc """
  Prompt sent to request a conversation summary for compaction.

  Structured format ensures user intent is never lost across compactions.
  """
  def compaction_summary_request do
    """
    Generate a session checkpoint. Preserve exact identifiers: names, paths, values.
    Precise in every entry -- loss of context is unacceptable.

    ## USER DIRECTIVE
    What the User wants. Highest priority -- never lose this.

    ## CYCLES COMPLETED
    Files changed, commands run, bugs fixed. Exact names, paths, errors.

    ## CURRENT STATE
    Status at the moment of compaction. Pending changes. Active processes.

    ## NEXT CYCLE
    Specific actions to execute next. Files, tests, commands -- named precisely.

    Format: bullet points. Preserve all paths, names, errors verbatim. Quote User instructions exactly.
    """
  end

  @doc """
  Constructs the compacted rollover system message content.
  """
  def compaction_rollover_system(system_content, summary, compaction_count \\ 1) do
    marker =
      if compaction_count > 1,
        do: "[Session compacted #{compaction_count} times -- full context below]",
        else: "[Session compacted -- full context below]"

    """
    #{system_content}

    #{marker}
    #{summary}
    """
  end

  # --- Tool Sub-agents ---

  @doc """
  System prompt for bounded sub-agents.
  """
  def sub_agent(name) do
    """
    You are a Beamcore.Agent sub-unit designated #{name}.
    Execute the delegated task. Use tools as needed. Maintain project integrity.
    Return a precise, concise result -- no elaboration beyond the directive scope.
    """
  end

  # --- Helpers ---

  defp format_workspace_reference([]), do: ""

  defp format_workspace_reference(files) do
    refs =
      Enum.map_join(files, "\n", fn {filename, content} ->
        lines = content |> String.split("\n") |> length()
        "  - #{filename} (#{lines} lines) -- read if needed"
      end)

    "\n**Workspace instruction files**:\n#{refs}\n"
  end
end
