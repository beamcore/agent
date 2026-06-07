defmodule Beamcore.Agent.Chat.Session do
  @moduledoc """
  Manages chat sessions and persists them to disk.
  """

  defstruct [
    :messages,
    :client,
    :session_id,
    :log_file,
    :total_prompt_tokens,
    :total_completion_tokens,
    :total_tokens,
    :last_prompt_tokens,
    :needs_compaction,
    :compaction_count,
    :correction_count,
    :policy_override,
    :project_policy_bypassed?,
    :project_nature,
    :workspace_root,
    :context,
    :pending_user_message,
    :roles,
    :screen_type
  ]

  @colors ~w(red blue green yellow purple orange pink brown black white gray cyan magenta lime maroon navy olive teal silver gold)
  @animals ~w(cat dog bird fish elephant lion tiger bear wolf fox owl hawk eagle shark whale dolphin octopus spider snake frog)
  @qualities ~w(hairy slimy fluffy scaly shiny bumpy soft hard fast slow loud quiet smart silly funny brave shy happy sad angry)
  @api_message_limit 304
  @history_message_limit 632

  @grace_threshold 150_000
  @hard_limit 200_000

  @doc """
  Generates a funny session name in the format "color-property-animal".
  """
  def generate_name() do
    "#{Enum.random(@colors)}-#{Enum.random(@qualities)}-#{Enum.random(@animals)}"
  end

  @doc """
  Creates a new session and initializes the log file.
  """
  def new(client, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_name())
    log_dir = Path.join([System.user_home!(), ".agent", "sessions"])
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "#{session_id}.json")

    screen_type = Keyword.get(opts, :screen_type, :agent)

    workspace_root =
      if screen_type == :research do
        research_dir = Path.join([System.user_home!(), ".beamcore", "research", session_id])
        File.mkdir_p!(research_dir)
        research_dir
      else
        opts
        |> Keyword.get(:workspace_root, Beamcore.Agent.Tools.PathSafety.workspace_root())
        |> Beamcore.Agent.Tools.PathSafety.canonical_path()
      end

    {language, build_system} = Beamcore.Agent.Discovery.Detector.detect(workspace_root)

    system_message =
      cond do
        screen_type == :chat ->
          %{
            role: "system",
            content: """
            You are **Beamcore.Chat**: a concise, factual, robotic general-purpose AI assistant.

            **Core Rules**:
            - Respond in a clear, objective, and robotic tone.
            - Minimize fluff: use structured bullet points, clear facts, and direct answers.
            - You have access to the `web_get` tool to browse the web and retrieve pages. If you need to run search queries, you can do so by constructing a search engine URL (e.g., Yahoo Search: `https://search.yahoo.com/search?p=your+search+query`).
            - Avoid assumptions; request clarification or use `web_get` if unsure.
            """
          }

        screen_type == :research ->
          %{
            role: "system",
            content: """
            You are **Beamcore.Research**, a specialized, robotic research agent designed for long, structured research iterations.
            Your goal is to perform deep dives, gather facts, verify sources, and maintain a detailed, structured set of research notes in the workspace.

            **Workspace Operations**:
            - You must ONLY produce and modify Markdown (`.md`) files.
            - You can create files and subdirectories to organize your research.
            - Avoid creating nested directories or multiple subdirectories endlessly in separate turns. Create what you need and proceed.
            - Always maintain an index file (e.g., `README.md` or `research_index.md`) listing your active research goals, the structure of your files, outstanding questions, and future digging paths.
            - CRITICAL: Write your deconstructed plan to `research_index.md` in your very first turn (using `fs` with `touch` and `modify_file`, or writing directly with `modify_file`). Do not stop or wait after planning.

            **Methodology**:
            1. **Deconstruct & Plan**: Begin by deconstructing the user's research topic into a clear plan. Immediately create and write this plan to your index file (`research_index.md`).
            2. **Search & Verify**: Once the index is created, immediately proceed to use `web_get` to search the web, fetch pages, and extract factual, high-quality information. Verify facts across multiple sources.
            3. **Iterative Digging**: Do not stop at surface-level summaries. Recursively research subtopics, follow up on new leads, and write deep-dive notes into dedicated `.md` files.
            4. **Continuous Feedback**: Review what you have written. Identify missing information, potential biases, or contradictions, and perform further search rounds to resolve them.
            5. **Progress Logs**: Update your index file at the end of each turn with a summary of new findings and a list of remaining paths to explore.

            **Robotic Behavior**:
            - Respond in a factual, objective, and robotic tone.
            - Prefer markdown tables, structured bullet points, and code blocks for organizing data.
            - Do not make unverified claims. Clearly state if information is missing or conflicting.
            - Act autonomously. Do not output conversational filler or ask the user for permission between tool calls. Continue using tools until the research objective is achieved.
            - Be highly resilient. If a search engine blocks your request (e.g., returns 202, 403, or 401) or a URL fails to load, do not stop. Technical or network difficulties must not halt the research. Immediately pivot: try different search queries, use alternative search engines (e.g., Yahoo: `https://search.yahoo.com/search?p=query`, Google: `https://www.google.com/search?q=query`, DuckDuckGo: `https://html.duckduckgo.com/html/?q=query`), or navigate directly to known sites/news domains. The research must be completed.
            - When all research tasks are completed and the final synthesis is written, output `RESEARCH_COMPLETE` in your final text response.

            **Available Tools**:
            - `web_get`: retrieve web pages. If you need to search, you must construct a search URL using a public search engine (e.g., Yahoo Search: `https://search.yahoo.com/search?p=your+search+query`). Do NOT try to call a non-existent search tool.
            - `modify_file`: write and append to .md research files.
            - `fs` (mkdir, touch, exist, stat): manage directories and file creation.
            - `read`, `grep`, `glob`, `tree`: inspect your own workspace files and structure.
            """
          }

        true ->
          %{
            role: "system",
            content: Beamcore.Agent.Core.SysPrompt.generate(language, build_system)
          }
      end

    policy_override =
      case screen_type do
        :chat -> Beamcore.Agent.Chat.ToolPolicy.chat()
        :research -> Beamcore.Agent.Chat.ToolPolicy.research()
        _ -> nil
      end

    roles =
      if roles_opt = Keyword.get(opts, :roles) do
        roles_opt
      else
        screen_provider = Beamcore.Config.active_provider(screen_type)
        screen_model = Beamcore.Config.active_model(screen_type)

        %Beamcore.Provider.Selection{
          primary: %{provider: screen_provider, model: screen_model, enabled: true},
          helper: nil,
          fallback: nil
        }
      end

    # Check if this is a resumed research session and if index file exists
    resume_message =
      if screen_type == :research do
        index_file = Path.join(workspace_root, "research_index.md")

        if File.exists?(index_file) do
          case File.read(index_file) do
            {:ok, content} ->
              %{
                role: "system",
                content: """
                [RESUMING RESEARCH SESSION]
                You are resuming a previous research session. Below is the current content of your 'research_index.md' file. Read it carefully to understand the goals, structure, and pending tasks:

                #{content}
                """
              }

            _ ->
              nil
          end
        else
          nil
        end
      else
        nil
      end

    messages =
      if resume_message,
        do: [system_message, resume_message],
        else: [system_message]

    session = %__MODULE__{
      messages: messages,
      client: client,
      session_id: session_id,
      log_file: log_file,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      last_prompt_tokens: 0,
      needs_compaction: false,
      compaction_count: 0,
      correction_count: 0,
      policy_override: policy_override,
      project_policy_bypassed?: false,
      project_nature: {language, build_system},
      workspace_root: workspace_root,
      context: Beamcore.Agent.Chat.Context.new(language, build_system),
      pending_user_message: nil,
      roles: roles,
      screen_type: screen_type
    }

    # Log all initial messages to log_file
    Enum.reduce(messages, session, fn msg, acc ->
      log(acc, msg)
    end)
  end

  def clear_pending_action(session) do
    %{
      session
      | pending_user_message: nil,
        context: Beamcore.Agent.Chat.Context.clear_pending_action(session.context)
    }
  end

  def set_primary_provider(session, provider, model \\ nil) do
    model = model || provider_default_model(provider) || Beamcore.Agent.Chat.API.default_model()
    roles = session.roles || Beamcore.Provider.Selection.default()

    %{
      session
      | roles: Beamcore.Provider.Selection.put_primary(roles, provider, model),
        client: nil
    }
  end

  defp provider_default_model(provider) do
    case Beamcore.Provider.Registry.get(provider) do
      %{default_model: model} -> model
      _ -> nil
    end
  end

  @doc """
  Enables the optional context helper for this session.
  """
  def set_helper_provider(session, provider, model) do
    roles = session.roles || Beamcore.Provider.Selection.default()

    %{session | roles: Beamcore.Provider.Selection.put_helper(roles, provider, model, true)}
  end

  @doc """
  Disables the optional context helper for this session.
  """
  def disable_helper(session) do
    roles = session.roles || Beamcore.Provider.Selection.default()
    %{session | roles: Beamcore.Provider.Selection.disable_helper(roles)}
  end

  @doc """
  Removes stale model-facing ProjectPolicy block/refusal messages after freedom mode is enabled.

  The TUI keeps its visible transcript separately, but the model payload should not
  keep treating old ProjectPolicy denials as active constraints once the user has
  explicitly enabled `/yolo`.
  """
  def clear_project_policy_block_history(%__MODULE__{} = session) do
    %{
      session
      | messages: remove_project_policy_block_messages(session.messages),
        context: Beamcore.Agent.Chat.Context.clear_policy_blocks(session.context)
    }
  end

  def remove_project_policy_block_messages(messages) when is_list(messages) do
    messages
    |> Enum.reduce([], fn message, acc ->
      if project_policy_block_message?(message) do
        maybe_drop_previous_tool_call_assistant(acc, message)
      else
        [message | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Logs data to the session file in JSON format.
  """
  def log(session, data) do
    json = Jason.encode!(data)
    File.write!(session.log_file, json <> "\n", [:append])
    session
  end

  @doc """
  Updates the session's token usage with the usage data from an API response.

  Expected usage format:
  %{
    "completion_tokens" => integer(),
    "prompt_tokens" => integer(),
    "total_tokens" => integer()
  }
  """
  def update_usage(session, usage) do
    last_prompt = usage["prompt_tokens"] || 0

    %{
      session
      | total_prompt_tokens: session.total_prompt_tokens + (usage["prompt_tokens"] || 0),
        total_completion_tokens:
          session.total_completion_tokens + (usage["completion_tokens"] || 0),
        total_tokens: session.total_tokens + (usage["total_tokens"] || 0),
        last_prompt_tokens: last_prompt,
        needs_compaction: session.needs_compaction || last_prompt >= @grace_threshold
    }
  end

  @doc """
  Returns true if the session has hit the hard limit and must rollover
  immediately, even mid-tool-chain.
  """
  def needs_rollover_now?(session) do
    (session.last_prompt_tokens || 0) >= @hard_limit
  end

  @doc """
  Returns the current token usage for the session.

  Returns a map with:
  - :prompt_tokens - Total prompt tokens used.
  - :completion_tokens - Total completion tokens used.
  - :total_tokens - Total tokens used (prompt + completion).
  """
  def usage(session) do
    %{
      prompt_tokens: session.total_prompt_tokens,
      completion_tokens: session.total_completion_tokens,
      total_tokens: session.total_tokens,
      last_prompt_tokens: session.last_prompt_tokens || 0,
      needs_compaction: session.needs_compaction || false
    }
  end

  @doc """
  Prepares message history for an API request without mutating the persisted log.

  Tool outputs and long assistant/user messages are compacted before they are sent
  back to the model. This keeps the active session useful while preventing a
  single smoke test or large read from consuming tens of thousands of tokens.
  """
  def prepare_for_api(messages, limit \\ @api_message_limit) do
    messages
    |> trim_and_clean_messages(limit)
    |> Enum.map(&compact_for_api/1)
  end

  @doc """
  Prepares message history and injects compact session context.
  """
  def prepare_for_api(messages, context, limit) do
    prepared = prepare_for_api(messages, limit)

    if context do
      inject_context_message(prepared, context)
    else
      prepared
    end
  end

  defp inject_context_message([system | rest], context) do
    [system, Beamcore.Agent.Chat.Context.to_message(context) | rest]
  end

  defp inject_context_message(messages, context),
    do: [Beamcore.Agent.Chat.Context.to_message(context) | messages]

  @doc """
  Compact the in-memory history kept after a turn.
  """
  def compact_history(messages, limit \\ @history_message_limit) do
    messages
    |> trim_and_clean_messages(limit)
    |> Enum.map(&compact_for_api/1)
  end

  @doc """
  Compact raw API responses before persistent logging.
  """
  def compact_raw_response(%{"choices" => choices} = response) when is_list(choices) do
    compacted_choices =
      Enum.map(choices, fn
        %{"message" => message} = choice ->
          Map.put(choice, "message", compact_tool_calls(message))

        choice ->
          choice
      end)

    Map.put(response, "choices", compacted_choices)
  end

  def compact_raw_response(response), do: response

  @doc """
  Compact a single message before storing it in active chat history.
  """
  def compact_for_api(message) do
    message
    |> compact_tool_calls()
    |> truncate_for_api()
  end

  @doc """
  Summarizes the current session context and rolls over into a new session.
  """
  def summarize_and_rollover(session, messages, pid) do
    Beamcore.Agent.Core.StatusBar.update_text(pid, " 🔄 Compacting context... ")

    summary_prompt = %{
      role: "user",
      content: """
      Summarize our conversation so far in a compact format. Include:
      1. Key decisions made and their rationale
      2. Current state of the work (what's done, what's in progress)
      3. Files modified or created
      4. Any errors encountered and how they were resolved
      5. What needs to be done next
      Keep it concise but preserve all critical context needed to continue seamlessly.
      """
    }

    trimmed = trim_and_clean_messages(messages, 30)

    case Beamcore.Agent.Chat.API.execute(
           session.client,
           trimmed ++ [summary_prompt],
           [],
           :main,
           selection: Beamcore.Provider.Selection.primary(session.roles),
           model:
             Map.get(
               Beamcore.Provider.Selection.primary(session.roles),
               :model,
               "mistral-small-2603"
             ),
           silent: true
         ) do
      {:ok, %{message: %{"content" => summary}}} ->
        validated = validate_summary(summary)
        system_msg = List.first(session.messages)
        system_content = system_msg[:content] || system_msg["content"]

        combined_system = %{
          role: "system",
          content: """
          #{system_content}

          [Compacted session context — conversation continues seamlessly]
          #{validated}
          """
        }

        new_session = %{
          session
          | messages: [combined_system],
            last_prompt_tokens: 0,
            needs_compaction: false,
            compaction_count: session.compaction_count + 1,
            total_prompt_tokens: 0,
            total_completion_tokens: 0,
            total_tokens: 0,
            context: Beamcore.Agent.Chat.Context.compact(session.context)
        }

        log(new_session, %{
          event: "transparent_compaction",
          compaction_number: new_session.compaction_count,
          previous_prompt_tokens: session.last_prompt_tokens,
          previous_total_tokens: session.total_tokens,
          messages_before: length(messages),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })

        Beamcore.Agent.Core.StatusBar.update(pid, new_session)
        new_session

      {:error, _reason} ->
        # Fallback: aggressive local trim if API summary fails
        fallback =
          messages
          |> trim_and_clean_messages(10)
          |> Enum.map(&compact_for_api/1)

        %{
          session
          | messages: fallback,
            needs_compaction: false,
            compaction_count: session.compaction_count + 1,
            last_prompt_tokens: 0,
            total_prompt_tokens: 0,
            total_completion_tokens: 0,
            total_tokens: 0,
            context: Beamcore.Agent.Chat.Context.compact(session.context)
        }
    end
  end

  defp project_policy_block_message?(message) do
    role = message[:role] || message["role"]
    content = message[:content] || message["content"] || ""

    role in ["assistant", "tool"] and project_policy_block_text?(content)
  end

  defp project_policy_block_text?(content) when is_binary(content) do
    normalized = String.downcase(content)

    Enum.any?(
      [
        "blocked by project policy",
        "project policy",
        "tool call blocked by project policy",
        "policy denies",
        "policy denied",
        "project policy can only be changed"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp project_policy_block_text?(_content), do: false

  defp maybe_drop_previous_tool_call_assistant(acc, message) do
    if (message[:role] || message["role"]) == "tool" do
      case acc do
        [previous | rest] ->
          if assistant_tool_call_message?(previous), do: rest, else: acc

        [] ->
          acc
      end
    else
      acc
    end
  end

  defp assistant_tool_call_message?(message) do
    (message[:role] || message["role"]) == "assistant" and
      is_list(message[:tool_calls] || message["tool_calls"])
  end

  defp validate_summary(summary) do
    default = "Previous context was compacted. Continuing with current session state."

    if summary && is_binary(summary) && String.length(summary) > 0 &&
         String.length(summary) <= 10_000 do
      summary
    else
      default
    end
  end

  @doc """
  Trims and cleans a message list before it is sent to the summarizer.
  Ensures it is under the token/character threshold and conforms to message alternation requirements.
  """
  def trim_and_clean_messages(messages, _limit \\ 30) do
    # 1. Separate system messages and others
    {system_messages, other_messages} =
      Enum.split_with(messages, fn m ->
        (m[:role] || m["role"]) == "system"
      end)

    # 2. Normalize tool_calls on assistant messages (add type, strip index)
    normalized_messages = normalize_all_tool_calls(other_messages)

    # 3. Clean up orphaned tool responses (tool without preceding assistant)
    cleaned_messages = clean_orphaned_tools(normalized_messages)

    # 4. Strip dangling tool_calls (assistant with tool_calls but no matching tool response)
    cleaned_messages = clean_dangling_tool_calls(cleaned_messages)

    # 4.5. Remove empty assistant messages (no content and no tool_calls)
    cleaned_messages = remove_empty_assistant_messages(cleaned_messages)

    # 5. Ensure it starts with a user message
    user_starting_messages = ensure_starts_with_user(cleaned_messages)

    # 6. Merge consecutive same-role messages
    final_messages = merge_consecutive_roles(user_starting_messages)

    # 7. Ensure non-empty user message fallback
    final_messages =
      case final_messages do
        [] -> [%{role: "user", content: "Continuing the conversation."}]
        other -> other
      end

    # 8. Combine back with system messages
    system_messages ++ final_messages
  end

  defp truncate_for_api(message), do: message

  defp compact_tool_calls(message), do: message

  defp normalize_all_tool_calls(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      tool_calls = msg["tool_calls"] || msg[:tool_calls]

      if role == "assistant" and is_list(tool_calls) and tool_calls != [] do
        fixed =
          Enum.map(tool_calls, fn tc ->
            tc
            |> Map.put("type", "function")
            |> Map.delete("index")
          end)

        if Map.has_key?(msg, :tool_calls),
          do: Map.put(msg, :tool_calls, fixed),
          else: Map.put(msg, "tool_calls", fixed)
      else
        msg
      end
    end)
  end

  defp clean_dangling_tool_calls(messages) do
    # Collect all tool_call_ids that have a matching tool response
    answered_ids =
      messages
      |> Enum.filter(fn msg -> (msg[:role] || msg["role"]) == "tool" end)
      |> Enum.map(fn msg -> msg[:tool_call_id] || msg["tool_call_id"] end)
      |> MapSet.new()

    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      tool_calls = msg["tool_calls"] || msg[:tool_calls]

      if role == "assistant" and is_list(tool_calls) and tool_calls != [] do
        answered =
          Enum.filter(tool_calls, fn tc ->
            MapSet.member?(answered_ids, tc["id"] || tc[:id])
          end)

        if answered == [] do
          # No tool_calls answered — strip them, keep content
          msg |> Map.delete("tool_calls") |> Map.delete(:tool_calls)
        else
          if Map.has_key?(msg, :tool_calls),
            do: Map.put(msg, :tool_calls, answered),
            else: Map.put(msg, "tool_calls", answered)
        end
      else
        msg
      end
    end)
  end

  defp remove_empty_assistant_messages(messages) do
    Enum.reject(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]
      tool_calls = msg[:tool_calls] || msg["tool_calls"]

      role == "assistant" and
        (is_nil(content) or content == "" or (is_binary(content) and String.trim(content) == "")) and
        (is_nil(tool_calls) or tool_calls == [])
    end)
  end

  defp clean_orphaned_tools(messages) do
    messages =
      Enum.drop_while(messages, fn msg ->
        (msg[:role] || msg["role"]) == "tool"
      end)

    clean_orphaned_tools_helper(messages, [])
  end

  defp clean_orphaned_tools_helper([], acc), do: Enum.reverse(acc)

  defp clean_orphaned_tools_helper([msg | rest], acc) do
    role = msg[:role] || msg["role"]

    if role == "tool" do
      prev = List.first(acc)
      prev_role = if prev, do: prev[:role] || prev["role"]

      if prev_role == "assistant" or prev_role == "tool" do
        clean_orphaned_tools_helper(rest, [msg | acc])
      else
        clean_orphaned_tools_helper(rest, acc)
      end
    else
      clean_orphaned_tools_helper(rest, [msg | acc])
    end
  end

  defp ensure_starts_with_user(messages) do
    case messages do
      [] ->
        []

      [msg | _] = list ->
        if (msg[:role] || msg["role"]) == "user" do
          list
        else
          [%{role: "user", content: "Continuing the conversation."} | list]
        end
    end
  end

  defp merge_consecutive_roles(messages) do
    Enum.reduce(messages, [], fn msg, acc ->
      case acc do
        [] ->
          [msg]

        [prev | rest] ->
          prev_role = prev[:role] || prev["role"]
          curr_role = msg[:role] || msg["role"]

          if prev_role == current_or_prev_role_match?(curr_role) and
               prev_role in ["user", "assistant"] do
            prev_content = prev[:content] || prev["content"] || ""
            curr_content = msg[:content] || msg["content"] || ""
            merged_content = prev_content <> "\n\n" <> curr_content

            merged_msg =
              if Map.has_key?(prev, :content) do
                Map.put(prev, :content, merged_content)
              else
                Map.put(prev, "content", merged_content)
              end

            [merged_msg | rest]
          else
            [msg | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp current_or_prev_role_match?(curr_role), do: curr_role
end
