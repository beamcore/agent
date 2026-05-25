defmodule Beamcore.Agent.Chat.CorrectionCatch do
  @moduledoc """
  Detects and corrects loops where the assistant is stuck or repeating unconstructive patterns.
  """

  alias Beamcore.Agent.Chat.{API, Session, Context}
  alias Beamcore.Agent.Core.StatusBar

  @triggers [
    "actually",
    "too complicated",
    "too complex",
    "apologiz",
    "apologies",
    "loop",
    "mistake",
    "let me try",
    "let's try",
    "unable to"
  ]

  @doc """
  Check if the assistant is stuck in a repetitive loop.
  Returns true if the last 5 assistant messages all contain at least one trigger phrase.
  """
  def stuck?(messages) when is_list(messages) do
    assistant_messages =
      messages
      |> Enum.filter(fn msg ->
        role = msg[:role] || msg["role"]
        role == "assistant"
      end)

    if length(assistant_messages) >= 5 do
      assistant_messages
      |> Enum.take(-5)
      |> Enum.all?(&matches_trigger?/1)
    else
      false
    end
  end

  def stuck?(_), do: false

  defp matches_trigger?(msg) do
    content = (msg[:content] || msg["content"] || "") |> String.downcase()
    Enum.any?(@triggers, &String.contains?(content, &1))
  end

  @doc """
  Performs the correction by calling the LLM to summarize the session, diagnose the failure,
  and formulate corrected actions. Then rolls over/compacts the session context.
  """
  def correct_and_rollover(session, messages, pid) do
    if pid, do: StatusBar.update_text(pid, " ⚠️ Loop detected! Correcting... ")

    correction_prompt = %{
      role: "user",
      content: """
      Our agent loop has detected that the assistant has gotten stuck in a repetitive loop (repeatedly saying 'Actually', 'This is too complicated', apologizing, or making/repeating the same error).
      Please analyze the conversation and provide:
      1. A concise summary of the conversation so far (key decisions, state of work, files touched).
      2. A diagnosis of the bad behavior (why did the agent get stuck or keep repeating?).
      3. A set of concrete, corrected actions the model MUST take to proceed and successfully finish the task.

      Format your response clearly so the agent can learn from this correction and proceed.
      """
    }

    trimmed = Session.trim_and_clean_messages(messages, 30)

    # Call the API to generate the summary, diagnosis, and corrected actions
    case API.execute(
           session.client,
           trimmed ++ [correction_prompt],
           [],
           :main,
           model: API.default_model()
         ) do
      {:ok, %{message: %{"content" => correction_content}}} ->
        system_msg = List.first(session.messages)
        system_content = system_msg[:content] || system_msg["content"]

        combined_system = %{
          role: "system",
          content: """
          #{system_content}

          ⚠️ SYSTEM INTERRUPT: The conversation was interrupted because the assistant was stuck in a repetitive loop.
          The following diagnosis and corrected actions have been formulated to break the loop:

          #{correction_content}

          Please carefully review the diagnosis, strictly follow the corrected actions, and proceed with the task.
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
            context: Context.compact(session.context)
        }

        Session.log(new_session, %{
          event: "correction_compaction",
          compaction_number: new_session.compaction_count,
          previous_prompt_tokens: session.last_prompt_tokens,
          previous_total_tokens: session.total_tokens,
          messages_before: length(messages),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })

        if pid, do: StatusBar.update(pid, new_session)
        new_session

      {:error, reason} ->
        # Fallback if API call fails
        IO.puts(:stderr, "Error executing correction API: #{inspect(reason)}. Proceeding with aggressive session compaction fallback.")
        Session.summarize_and_rollover(session, messages, pid)
    end
  end
end
