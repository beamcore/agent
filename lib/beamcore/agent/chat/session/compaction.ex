defmodule Beamcore.Agent.Chat.Session.Compaction do
  @moduledoc """
  Message compaction, API preparation, and session rollover logic.

  Handles preparing message histories for API calls (with context injection and budget fitting),
  compacting histories after turns, compacting raw API responses, and performing transparent
  session rollovers with summarization.
  """

  alias Beamcore.Agent.Chat.Session.MessageCleaner

  @api_message_limit 304
  @history_message_limit 632

  @doc """
  Prepares message history for an API request without mutating the persisted log.

  Tool outputs and long assistant/user messages are compacted before they are sent
  back to the model.
  """
  def prepare_for_api(messages, limit \\ @api_message_limit) do
    messages
    |> MessageCleaner.trim_and_clean(limit)
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

  @doc """
  Compact the in-memory history kept after a turn.
  """
  def compact_history(messages, limit \\ @history_message_limit) do
    messages
    |> MessageCleaner.trim_and_clean(limit)
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

    trimmed = MessageCleaner.trim_and_clean(messages, 30)

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
          Beamcore.Agent.Chat.Session.TimelineOps.append_timeline(
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

        Beamcore.Agent.Core.StatusBar.update(pid, new_session)
        new_session

      {:error, _reason} ->
        fallback =
          messages
          |> MessageCleaner.trim_and_clean(10)
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
        |> Beamcore.Agent.Chat.Session.TimelineOps.append_timeline(
          :compression,
          "Session context compacted with local fallback."
        )
    end
  end

  defp inject_context_message([system | rest], context) do
    [system, Beamcore.Agent.Chat.Context.to_message(context) | rest]
  end

  defp inject_context_message(messages, context),
    do: [Beamcore.Agent.Chat.Context.to_message(context) | messages]

  defp truncate_for_api(message), do: message

  defp compact_tool_calls(message), do: message

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
