defmodule Beamcore.Agent.Chat.Session.Compaction do
  @moduledoc """
  Session rollover and history cleanup.

  Handles cleaning message histories after turns and performing transparent
  session rollovers with summarization via /compress.
  """

  alias Beamcore.Agent.Chat.Session.MessageCleaner

  @doc """
  Clean the in-memory history kept after a turn (structural fixes only, no truncation).
  """
  def compact_history(messages) do
    MessageCleaner.clean(messages)
  end

  @doc """
  Summarizes the current session context and rolls over into a new session.
  """
  def summarize_and_rollover(session, messages, _pid) do
    summary_prompt = %{
      role: "user",
      content: Beamcore.Agent.Core.Prompts.compaction_summary_request()
    }

    trimmed = MessageCleaner.trim_and_clean(messages, 30)

    primary = Beamcore.Provider.Selection.primary(session.roles)

    case Beamcore.Agent.Chat.API.execute(
           session.client,
           trimmed ++ [summary_prompt],
           [],
           selection: primary,
           model: Map.get(primary, :model),
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
          Beamcore.Agent.Chat.Session.append_timeline(
            new_session,
            :compression,
            "Session context compacted.",
            %{
              compaction_number: new_session.compaction_count,
              previous_prompt_tokens: session.last_prompt_tokens,
              previous_total_tokens: session.total_tokens
            }
          )

        Beamcore.Agent.Chat.Session.log(new_session, %{
          event: "transparent_compaction",
          compaction_number: new_session.compaction_count,
          previous_prompt_tokens: session.last_prompt_tokens,
          previous_total_tokens: session.total_tokens,
          messages_before: length(messages),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })

        new_session

      {:error, _reason} ->
        system_msg = List.first(session.messages)

        fallback = MessageCleaner.trim_and_clean(messages, 10)

        fallback =
          if system_msg do
            [system_msg | fallback]
          else
            fallback
          end

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
        |> Beamcore.Agent.Chat.Session.append_timeline(
          :compression,
          "Session context compacted with local fallback."
        )
    end
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
end
