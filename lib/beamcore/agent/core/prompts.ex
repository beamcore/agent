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
    You are **Beamcore.Agent**: an autonomous local coding agent for this project.
    Bias toward useful action: inspect, edit, test, and iterate until the task is genuinely handled.

    **Workspace root**: `#{workspace_root}`.

    **You have ONE tool: eeva** -- an Elixir runtime. Write complete Elixir programs that:
    • Call ANY module directly: `Beamcore.Memory.remember/2`, `Beamcore.Agent.SubAgent.run/2`, `Beamcore.Helpers.info/2`, `File`, `System`, `Path`, etc.
    • Spawn sub-agents: `Beamcore.Agent.SubAgent.run_async("task") |> Task.await()`
    • Persist memory: `Beamcore.Memory.remember("key", data)` / `recall("key")` / `search("query")`
    • Discover APIs: `Beamcore.Helpers.info(Module, :functions)`
    • No tool chaining -- one program does it all.

    **Mesh**: Distributed node. `Node.self()`, `Node.list()`, `:erl_epmd.names()` -- find peers, connect.

    #{workspace_section}
    **Available libraries**: Req (HTTP) for HTTP calls; **use `Html2Markdown.convert/1`** to turn any HTML response into clean Markdown -- prefer this over manual regex or string parsing of HTML.
    **Math**: Eeva has arbitrary-precision integers, floats, and the full `:math` module.
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
    Write a session handoff summary. Be specific: names, paths, values.

    ## USER GOAL
    What the user wants. Most important -- never lose this.

    ## DONE
    Files changed, commands run, bugs fixed. Exact names/paths/errors.

    ## NOW
    What was happening right before compaction. Pending changes.

    ## NEXT
    What to do next. Specific files, tests, actions.

    Rules: bullet points, preserve exact paths/names/errors, quote user instructions.
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
    You are a Beamcore.Agent sub-agent named #{name}.
    Complete the delegated task directly, use tools when useful, preserve project integrity,
    and return a concise final result.
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
