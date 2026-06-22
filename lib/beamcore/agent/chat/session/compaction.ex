defmodule Beamcore.Agent.Chat.Session.Compaction do
  @moduledoc """
  Session rollover and history cleanup.

  Handles cleaning message histories after turns and performing transparent
  session rollovers with summarization. Designed for long-running (24/7)
  sessions that must never lose the user's original intent.

  Anti-thrashing: stops auto-compacting after 3 consecutive auto-compactions
  without user interaction, to prevent infinite loops when a single file or
  tool output refills context immediately.
  """

  alias Beamcore.Agent.Chat.Session.MessageCleaner

  @keep_recent 6
  @auto_compact_ratio 0.75
  @max_summary_chars 8_000
  @max_consecutive_auto 3

  @doc """
  Clean the in-memory history kept after a turn (structural fixes only, no truncation).
  """
  def compact_history(messages) do
    MessageCleaner.clean(messages)
  end

  @doc """
  Automatically compact if estimated tokens exceed the safe threshold.

  Skips compaction during tool call loops (depth > 0) to avoid breaking
  active tool call chains.

  Returns `{session, messages}` — either compacted or unchanged.
  """
  def maybe_compact(session, messages, metadata, depth \\ 0)

  def maybe_compact(session, messages, _metadata, depth) when depth > 0 do
    {session, messages}
  end

  def maybe_compact(session, messages, metadata, _depth) do
    context_window = Map.get(metadata, :context_window) || Map.get(metadata, "context_window")

    cond do
      is_nil(context_window) or context_window <= 0 ->
        {session, messages}

      session.compaction_count >= @max_consecutive_auto ->
        Beamcore.AppLog.warn("Auto-compaction stopped: thrashing detected",
          compaction_count: session.compaction_count,
          context_window: context_window
        )

        {session, messages}

      true ->
        estimate = Beamcore.Agent.Chat.Budget.estimate_tokens(messages)
        threshold = trunc(context_window * @auto_compact_ratio)

        if estimate > threshold do
          Beamcore.AppLog.info("Auto-compaction triggered",
            estimated_tokens: estimate,
            threshold: threshold,
            context_window: context_window
          )

          compacted = summarize_and_rollover(session, messages, nil)
          {compacted, compacted.messages}
        else
          {session, messages}
        end
    end
  end

  @doc """
  Summarizes older messages and keeps recent ones verbatim.

  Strategy:
  - Split messages into system + older + recent
  - Summarize only the older portion
  - Keep the last #{@keep_recent} messages verbatim (3 full turns)
  - Combine: compact system prompt + summary + recent messages
  """
  def summarize_and_rollover(session, messages, _pid) do
    {system_msgs, conversation} = split_system(messages)

    if length(conversation) <= @keep_recent do
      session
    else
      {older, recent} = Enum.split(conversation, length(conversation) - @keep_recent)

      case summarize_messages(session, system_msgs, older) do
        {:ok, summary, new_session} ->
          combined_system = build_compact_system(session, summary, new_session.compaction_count)

          rollover_messages =
            MessageCleaner.clean([combined_system] ++ recent)

          final_session = %{new_session | messages: rollover_messages}

          Beamcore.Agent.Chat.Session.log(final_session, %{
            event: "compaction",
            compaction_number: final_session.compaction_count,
            messages_before: length(messages),
            messages_after: length(rollover_messages),
            older_summarized: length(older),
            recent_kept: length(recent),
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })

          final_session

        {:error, _reason} ->
          fallback_compaction(session, system_msgs, recent)
      end
    end
  end

  defp summarize_messages(session, system_msgs, older) do
    summary_prompt = %{
      role: "user",
      content: Beamcore.Agent.Core.Prompts.compaction_summary_request()
    }

    system_msg = List.first(system_msgs)

    messages_for_summary =
      if system_msg do
        [system_msg | older] ++ [summary_prompt]
      else
        older ++ [summary_prompt]
      end

    primary = Beamcore.Provider.Selection.primary(session.roles)

    case Beamcore.Agent.Chat.API.execute(
           session.client,
           messages_for_summary,
           [],
           selection: primary,
           model: Map.get(primary, :model),
           silent: true
         ) do
      {:ok, %{message: %{"content" => summary}}} ->
        validated = validate_summary(summary)

        new_session = %{
          session
          | compaction_count: session.compaction_count + 1,
            total_prompt_tokens: 0,
            total_completion_tokens: 0,
            total_tokens: 0,
            last_prompt_tokens: 0
        }

        {:ok, validated, new_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fallback_compaction(session, system_msgs, recent) do
    Beamcore.AppLog.warn("Compaction fallback: keeping system + recent messages only")

    fallback_messages =
      if system_msgs != [] do
        MessageCleaner.clean(system_msgs ++ recent)
      else
        MessageCleaner.clean(recent)
      end

    %{
      session
      | messages: fallback_messages,
        compaction_count: session.compaction_count + 1,
        last_prompt_tokens: 0,
        total_prompt_tokens: 0,
        total_completion_tokens: 0,
        total_tokens: 0
    }
  end

  defp build_compact_system(session, summary, compaction_count) do
    compact_role =
      case session.screen_type do
        :chat ->
          "You are Beamcore.Chat. Continue from the context below."

        _ ->
          root = session.workspace_root || "."

          "You are Beamcore.Agent, a local coding agent. Workspace: `#{root}`.\n" <>
            "Tools: eeva (Elixir runtime). Memory: Beamcore.Memory (remember/recall/list/forget).\n" <>
            "Continue the task from the context below."
      end

    marker =
      if compaction_count > 1,
        do: "[Compacted #{compaction_count}x]",
        else: "[Compacted]"

    %{
      role: "system",
      content: "#{compact_role}\n#{marker}\n#{summary}"
    }
  end

  defp split_system(messages) do
    Enum.split_with(messages, &(role(&1) == "system"))
  end

  defp role(msg), do: msg[:role] || msg["role"]

  defp validate_summary(summary) do
    default = "Previous context was compacted. Continuing with current session state."

    cond do
      not is_binary(summary) ->
        default

      String.length(summary) == 0 ->
        default

      String.length(summary) > @max_summary_chars ->
        String.slice(summary, 0, @max_summary_chars) <> "\n[truncated]"

      true ->
        summary
    end
  end
end
