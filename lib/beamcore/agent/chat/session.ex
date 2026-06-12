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
    :runtime_caps,
    :project_nature,
    :workspace_root,
    :context,
    :roles,
    :screen_type,
    :mode_settings,
    :timeline,
    :checkpoints,
    :branches,
    :branch_id,
    :active_checkpoint_id,
    :state_file,
    :checkpoint_file,
    :intermediate_state,
    :interrupted?
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
    state_file = Path.join(log_dir, "#{session_id}.state.json")
    checkpoint_file = Path.join(log_dir, "#{session_id}.checkpoints.json")

    screen_type = Keyword.get(opts, :screen_type, :agent)
    mode_settings = Beamcore.Agent.Chat.ModeSettings.resolve(screen_type)

    workspace_root =
      opts
      |> Keyword.get(:workspace_root, Beamcore.Agent.PathSafety.workspace_root())
      |> Beamcore.Agent.PathSafety.canonical_path()

    {language, build_system} = Beamcore.Agent.Discovery.Detector.detect(workspace_root)

    system_message =
      cond do
        screen_type == :chat ->
          %{
            role: "system",
            content: Beamcore.Agent.Core.Prompts.chat_agent()
          }

        true ->
          %{
            role: "system",
            content: Beamcore.Agent.Core.Prompts.dev_agent(language, build_system)
          }
      end

    runtime_caps = Beamcore.Agent.Chat.ToolRuntime.default()

    roles =
      if roles_opt = Keyword.get(opts, :roles) do
        roles_opt
      else
        %Beamcore.Provider.Selection{
          primary: %{
            provider: mode_settings.provider,
            model: mode_settings.model,
            enabled: true
          },
          fallback: nil
        }
      end

    messages = [system_message]

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
      runtime_caps: runtime_caps,
      project_nature: {language, build_system},
      workspace_root: workspace_root,
      context: Beamcore.Agent.Chat.Context.new(language, build_system),
      roles: roles,
      screen_type: screen_type,
      mode_settings: mode_settings,
      timeline: [],
      checkpoints: [],
      branches: Beamcore.Agent.Timeline.initial_branches(),
      branch_id: Beamcore.Agent.Timeline.initial_branch_id(),
      active_checkpoint_id: nil,
      state_file: state_file,
      checkpoint_file: checkpoint_file,
      intermediate_state: %{},
      interrupted?: false
    }

    # Log all initial messages to log_file
    session =
      Enum.reduce(messages, session, fn msg, acc ->
        log(acc, msg)
      end)

    session =
      append_timeline(session, :started, "Session started.",
        role: :system,
        title: "Session started",
        metadata: %{
          mode: mode_settings.mode,
          provider: mode_settings.provider,
          model: mode_settings.model
        }
      )

    if screen_type == :agent do
      checkpoint(session, "F1 Dev session started.", %{
        workflow_stage: "session_started",
        mode: "F1 Dev"
      })
    else
      session
    end
  end

  @doc """
  Resume a saved session state by id.
  """
  def resume(session_id, client, opts \\ []) when is_binary(session_id) do
    log_dir = Path.join([System.user_home!(), ".agent", "sessions"])
    state_file = Path.join(log_dir, "#{session_id}.state.json")

    with {:ok, content} <- File.read(state_file),
         {:ok, data} <- Jason.decode(content) do
      {:ok, restore(data, client, opts)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def set_primary_provider(session, provider, model \\ nil) do
    model = model || provider_default_model(provider) || Beamcore.Agent.Chat.API.default_model()
    roles = session.roles || Beamcore.Provider.Selection.default()

    mode_settings =
      session.mode_settings || Beamcore.Agent.Chat.ModeSettings.resolve(session.screen_type)

    %{
      session
      | roles: Beamcore.Provider.Selection.put_primary(roles, provider, model),
        mode_settings: %{mode_settings | provider: provider, model: model},
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
  Logs data to the session file in JSON format.
  """
  def log(session, data) do
    json = Jason.encode!(data)
    File.write!(session.log_file, json <> "\n", [:append])
    session
  end

  def append_timeline(session, type, summary, attrs \\ []) when is_atom(type) do
    attrs_map = normalize_event_attrs(attrs)

    event =
      Beamcore.Agent.Timeline.event(session, %{
        type: type,
        role: Map.get(attrs_map, :role),
        title: Map.get(attrs_map, :title),
        summary: summary,
        status: Map.get(attrs_map, :status, :completed),
        reversible: Map.get(attrs_map, :reversible),
        metadata: Map.get(attrs_map, :metadata, %{})
      })

    session = %{session | timeline: (session.timeline || []) ++ [event]}
    checkpoint_attrs = Map.get(attrs_map, :checkpoint, :auto)

    session =
      if important_event?(event) and checkpoint_attrs != false do
        save_checkpoint(session, event, summary, normalize_checkpoint_attrs(checkpoint_attrs))
      else
        save_state(session)
      end

    log(session, %{
      event: "timeline",
      timeline: Beamcore.Agent.Timeline.to_json_event(event)
    })
  end

  defp normalize_checkpoint_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_checkpoint_attrs(_attrs), do: %{}

  defp normalize_event_attrs(attrs) when is_list(attrs), do: Enum.into(attrs, %{})

  defp normalize_event_attrs(attrs) when is_map(attrs) do
    known = [:role, :title, :status, :reversible, :metadata, :checkpoint]

    if Enum.any?(known, &Map.has_key?(attrs, &1)) do
      attrs
    else
      %{metadata: attrs}
    end
  end

  defp normalize_event_attrs(_attrs), do: %{}

  def checkpoint(session, message, data \\ %{}) do
    event =
      Beamcore.Agent.Timeline.event(session, %{
        type: :checkpoint_saved,
        role: :system,
        title: "Checkpoint saved",
        summary: message,
        status: :completed,
        reversible: true,
        metadata: data
      })

    session = %{session | timeline: (session.timeline || []) ++ [event]}
    save_checkpoint(session, event, message, data)
  end

  def interrupt(session, reason \\ "Session interrupted.") do
    %{session | interrupted?: true}
    |> append_timeline(:interrupted, reason,
      role: :user,
      title: "Session interrupted",
      reversible: true
    )
  end

  def resume_interrupted(session, reason \\ "Session resumed.") do
    %{session | interrupted?: false}
    |> append_timeline(:resumed, reason,
      role: :user,
      title: "Session resumed",
      reversible: false
    )
  end

  def rewind(session, checkpoint_id) do
    with checkpoint when not is_nil(checkpoint) <-
           Beamcore.Agent.Timeline.find_checkpoint(session, checkpoint_id),
         {:ok, filesystem_result} <-
           Beamcore.Agent.RestoreCoordinator.restore(session, checkpoint),
         {:ok, session} <- Beamcore.Agent.Timeline.rewind(session, checkpoint_id) do
      session =
        session
        |> annotate_latest_timeline_event(filesystem_result)
        |> save_state()

      {:ok, session}
    else
      nil -> {:error, "Checkpoint '#{checkpoint_id}' was not found."}
      {:error, reason} -> {:error, reason}
    end
  end

  def fork(session, checkpoint_id, title \\ nil) do
    with checkpoint when not is_nil(checkpoint) <-
           Beamcore.Agent.Timeline.find_checkpoint(session, checkpoint_id),
         {:ok, filesystem_result} <-
           Beamcore.Agent.RestoreCoordinator.restore(session, checkpoint),
         {:ok, session} <- Beamcore.Agent.Timeline.fork(session, checkpoint_id, title) do
      session =
        session
        |> annotate_latest_timeline_event(filesystem_result)
        |> save_state()

      {:ok, session}
    else
      nil -> {:error, "Checkpoint '#{checkpoint_id}' was not found."}
      {:error, reason} -> {:error, reason}
    end
  end

  def abandon_branch(session, branch_id, reason \\ "Branch abandoned.") do
    session
    |> Beamcore.Agent.Timeline.abandon_branch(branch_id, reason)
    |> save_state()
  end

  def save_state(session) do
    if session.state_file do
      Beamcore.Agent.Timeline.write_atomic!(session.state_file, snapshot(session))
    end

    if session.checkpoint_file do
      Beamcore.Agent.Timeline.write_atomic!(session.checkpoint_file, %{
        "schema_version" => Beamcore.Agent.Timeline.schema_version(),
        "session_id" => session.session_id,
        "active_checkpoint_id" => session.active_checkpoint_id,
        "branch_id" => session.branch_id,
        "branches" => stringify_branches(session.branches || %{}),
        "checkpoints" =>
          Enum.map(session.checkpoints || [], &Beamcore.Agent.Timeline.to_json_checkpoint/1)
      })
    end

    session
  end

  def annotate_filesystem_restore(session, filesystem_result) do
    annotate_latest_timeline_event(session, filesystem_result)
  end

  defp save_checkpoint(session, event, summary, attrs) do
    checkpoint = Beamcore.Agent.Timeline.checkpoint(session, event, attrs || %{})
    checkpoint_event = Beamcore.Agent.Timeline.checkpoint_event(session, checkpoint, summary)
    checkpoint_event = %{checkpoint_event | parent_event_id: event.id}

    session =
      %{
        session
        | active_checkpoint_id: checkpoint.id,
          checkpoints: (session.checkpoints || []) ++ [checkpoint],
          timeline: (session.timeline || []) ++ [checkpoint_event]
      }
      |> save_state()

    log(session, %{
      event: "checkpoint",
      checkpoint: Beamcore.Agent.Timeline.to_json_checkpoint(checkpoint)
    })
  end

  defp annotate_latest_timeline_event(session, filesystem_result) do
    timeline = session.timeline || []

    case List.pop_at(timeline, -1) do
      {nil, _events} ->
        session

      {event, events} ->
        summary = filesystem_summary(event.summary, filesystem_result)

        event = %{
          event
          | summary: summary,
            metadata:
              event.metadata
              |> Kernel.||(%{})
              |> Map.put(:filesystem_restore, filesystem_result)
        }

        %{session | timeline: events ++ [event]}
    end
  end

  defp filesystem_summary(summary, %{"conflict_count" => conflicts} = result)
       when conflicts > 0 do
    "#{summary} Agent changes rewound with #{result["reverted_mutations"]} mutation(s) reverted, #{result["preserved_external_changes"]} external change(s) preserved, and #{conflicts} conflict(s)."
  end

  defp filesystem_summary(summary, result) do
    "#{summary} Agent changes rewound with #{result["reverted_mutations"]} mutation(s) reverted. No external changes affected."
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
  def update_usage(session, %Beamcore.Provider.Usage{} = usage) do
    update_usage(session, Beamcore.Provider.Usage.to_raw_usage(usage))
  end

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

  def prepare_for_api(messages, context, limit, budget) do
    messages
    |> prepare_for_api(context, limit)
    |> Beamcore.Agent.Chat.Budget.fit_messages(budget)
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
      content: Beamcore.Agent.Core.Prompts.compaction_summary_request()
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
          content:
            Beamcore.Agent.Core.Prompts.compaction_rollover_system(system_content, validated)
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

        new_session =
          append_timeline(new_session, :compression, "Session context compacted.", %{
            compaction_number: new_session.compaction_count,
            previous_prompt_tokens: session.last_prompt_tokens,
            previous_total_tokens: session.total_tokens
          })

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
        |> append_timeline(:compression, "Session context compacted with local fallback.")
    end
  end

  defp snapshot(session) do
    %{
      "version" => 1,
      "session_id" => session.session_id,
      "log_file" => session.log_file,
      "state_file" => session.state_file,
      "checkpoint_file" => session.checkpoint_file,
      "messages" => stringify_messages(session.messages || []),
      "screen_type" => to_string(session.screen_type || :agent),
      "roles" => stringify_roles(session.roles),
      "timeline" => Enum.map(session.timeline || [], &Beamcore.Agent.Timeline.to_json_event/1),
      "checkpoints" =>
        Enum.map(session.checkpoints || [], &Beamcore.Agent.Timeline.to_json_checkpoint/1),
      "branches" => stringify_branches(session.branches || %{}),
      "branch_id" => session.branch_id,
      "active_checkpoint_id" => session.active_checkpoint_id,
      "usage" => %{
        "total_prompt_tokens" => session.total_prompt_tokens || 0,
        "total_completion_tokens" => session.total_completion_tokens || 0,
        "total_tokens" => session.total_tokens || 0,
        "last_prompt_tokens" => session.last_prompt_tokens || 0,
        "needs_compaction" => session.needs_compaction || false,
        "compaction_count" => session.compaction_count || 0,
        "correction_count" => session.correction_count || 0
      },
      "workspace_root" => session.workspace_root,
      "intermediate_state" => session.intermediate_state || %{},
      "interrupted" => session.interrupted? || false
    }
  end

  defp restore(data, client, opts) do
    screen_type =
      data
      |> Map.get("screen_type", "agent")
      |> mode_atom()

    mode_settings = Beamcore.Agent.Chat.ModeSettings.resolve(screen_type)
    timeline_state = Beamcore.Agent.Timeline.safe_restore(data)
    usage = Map.get(data, "usage", %{})
    workspace_root = Map.get(data, "workspace_root") || Keyword.get(opts, :workspace_root)
    Beamcore.Agent.FilesystemJournal.recover_incomplete_restores(workspace_root)
    {language, build_system} = Beamcore.Agent.Discovery.Detector.detect(workspace_root || ".")

    %__MODULE__{
      messages: safe_messages(Map.get(data, "messages", [])),
      client: client,
      session_id: Map.fetch!(data, "session_id"),
      log_file: Map.get(data, "log_file"),
      state_file: Map.get(data, "state_file"),
      checkpoint_file:
        Map.get(data, "checkpoint_file") ||
          Path.join(
            Path.dirname(Map.get(data, "state_file")),
            "#{Map.fetch!(data, "session_id")}.checkpoints.json"
          ),
      total_prompt_tokens: Map.get(usage, "total_prompt_tokens", 0),
      total_completion_tokens: Map.get(usage, "total_completion_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0),
      last_prompt_tokens: Map.get(usage, "last_prompt_tokens", 0),
      needs_compaction: Map.get(usage, "needs_compaction", false),
      compaction_count: Map.get(usage, "compaction_count", 0),
      correction_count: Map.get(usage, "correction_count", 0),
      runtime_caps:
        if(screen_type == :chat,
          do: Beamcore.Agent.Chat.ToolRuntime.chat(),
          else: nil
        ),
      project_nature: {language, build_system},
      workspace_root: workspace_root,
      context: Beamcore.Agent.Chat.Context.new(language, build_system),
      roles: restore_roles(Map.get(data, "roles"), mode_settings),
      screen_type: screen_type,
      mode_settings: mode_settings,
      timeline: timeline_state.timeline,
      checkpoints: timeline_state.checkpoints,
      branches: timeline_state.branches,
      branch_id: timeline_state.branch_id,
      active_checkpoint_id: timeline_state.active_checkpoint_id,
      intermediate_state: Map.get(data, "intermediate_state", %{}),
      interrupted?: Map.get(data, "interrupted", false)
    }
    |> append_timeline(:resumed, "Session resumed.",
      role: :system,
      title: "Session resumed",
      reversible: false,
      metadata: %{session_id: Map.get(data, "session_id")}
    )
  end

  defp stringify_messages(messages) do
    Enum.map(messages, fn message ->
      message
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()
    end)
  end

  defp safe_messages(messages) do
    Enum.map(messages, fn message ->
      Map.new(message, fn {key, value} -> {to_string(key), value} end)
    end)
  end

  defp stringify_roles(nil), do: nil
  defp stringify_roles(%Beamcore.Provider.Selection{} = roles), do: Map.from_struct(roles)
  defp stringify_roles(roles), do: roles

  defp restore_roles(nil, settings) do
    %Beamcore.Provider.Selection{
      primary: %{provider: settings.provider, model: settings.model, enabled: true},
      fallback: nil
    }
  end

  defp restore_roles(%{"primary" => primary} = roles, _settings) do
    %Beamcore.Provider.Selection{
      primary: safe_selection(primary),
      fallback: safe_selection(Map.get(roles, "fallback"))
    }
  end

  defp restore_roles(%{"primary" => primary, "fallback" => fallback}, _settings) do
    %Beamcore.Provider.Selection{
      primary: safe_selection(primary),
      fallback: safe_selection(fallback)
    }
  end

  defp restore_roles(roles, _settings), do: roles

  defp safe_selection(nil), do: nil

  defp safe_selection(selection) do
    %{
      provider: Map.get(selection, "provider") || Map.get(selection, :provider),
      model: Map.get(selection, "model") || Map.get(selection, :model),
      enabled: Map.get(selection, "enabled") || Map.get(selection, :enabled) || false
    }
  end

  defp stringify_branches(branches) do
    Map.new(branches, fn {id, branch} ->
      {id, Beamcore.Agent.Timeline.to_json_event(branch)}
    end)
  end

  defp important_event?(%{type: type}) do
    type in [
      :model_call,
      :tool_call,
      :file_change,
      :compression,
      :decision,
      :error,
      :interrupted,
      :rewound,
      :forked,
      :resumed,
      :completed,
      :failed
    ]
  end

  defp mode_atom("chat"), do: :chat
  defp mode_atom(_), do: :agent

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

      reasoning =
        msg[:reasoning] || msg["reasoning"] || msg[:reasoning_content] || msg["reasoning_content"]

      role == "assistant" and
        (is_nil(content) or content == "" or (is_binary(content) and String.trim(content) == "")) and
        (is_nil(tool_calls) or tool_calls == []) and
        (is_nil(reasoning) or reasoning == "" or
           (is_binary(reasoning) and String.trim(reasoning) == ""))
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
