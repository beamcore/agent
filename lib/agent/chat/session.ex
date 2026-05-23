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
    :project_nature,
    :context,
    :pending_user_message
  ]

  @colors ~w(red blue green yellow purple orange pink brown black white gray cyan magenta lime maroon navy olive teal silver gold)
  @animals ~w(cat dog bird fish elephant lion tiger bear wolf fox owl hawk eagle shark whale dolphin octopus spider snake frog)
  @qualities ~w(hairy slimy fluffy scaly shiny bumpy soft hard fast slow loud quiet smart silly funny brave shy happy sad angry)
  @api_message_limit 24
  @history_message_limit 32
  @max_tool_result_chars 1_200
  @max_assistant_chars 3_000
  @max_user_chars 4_000
  @max_system_chars 9_000
  @max_other_chars 2_000
  @max_tool_arg_chars 200
  @large_tool_arg_keys ~w(content old_string new_string patch patch_content diff prompt instructions)

  @doc """
  Generates a funny session name in the format "color-property-animal".
  """
  def generate_name() do
    "#{Enum.random(@colors)}-#{Enum.random(@qualities)}-#{Enum.random(@animals)}"
  end

  @doc """
  Creates a new session and initializes the log file.
  """
  def new(client) do
    session_id = generate_name()
    log_dir = Path.join([System.user_home!(), ".agent", "sessions"])
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "#{session_id}.json")

    project_nature = Beamcore.Agent.Discovery.Detector.detect()

    system_message = %{
      role: "system",
      content: Beamcore.Agent.Core.SysPrompt.generate(project_nature)
    }

    %__MODULE__{
      messages: [system_message],
      client: client,
      session_id: session_id,
      log_file: log_file,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      project_nature: project_nature,
      context: Beamcore.Agent.Chat.Context.new(project_nature),
      pending_user_message: nil
    }
    |> then(&log(&1, system_message))
  end

  def clear_pending_action(session) do
    %{
      session
      | pending_user_message: nil,
        context: Beamcore.Agent.Chat.Context.clear_pending_action(session.context)
    }
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
    %{
      session
      | total_prompt_tokens: session.total_prompt_tokens + usage["prompt_tokens"],
        total_completion_tokens: session.total_completion_tokens + usage["completion_tokens"],
        total_tokens: session.total_tokens + usage["total_tokens"]
    }
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
      total_tokens: session.total_tokens
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
    Beamcore.Agent.Core.Pretty.print_warning(
      "Token limit approaching. Summarizing and rolling over to a new session..."
    )

    Beamcore.Agent.Core.StatusBar.update_text(
      pid,
      " ⚠️  ROLLING OVER SESSION (Summarizing context...) "
    )

    summary_prompt = %{
      role: "user",
      content:
        "We are approaching the context limit. Please summarize the progress we've made so far, key decisions, the current state of the codebase, and what needs to be done next. This summary will be used to seed our next session so we can continue seamlessly."
    }

    trimmed_messages = trim_and_clean_messages(messages, 30)
    temp_messages = trimmed_messages ++ [summary_prompt]

    case Beamcore.Agent.Chat.API.execute(session.client, temp_messages, [], :main,
           model: "mistral-small-2603"
         ) do
      {:ok, %{message: %{"content" => summary}}} ->
        # Validate the summary content
        default_summary =
          "Previous session summary was empty or invalid. Continuing with a fresh session."

        validated_summary =
          if summary && is_binary(summary) && String.length(summary) > 0 &&
               String.length(summary) <= 10_000 do
            summary
          else
            default_summary
          end

        new_session = new(session.client)

        # Explicitly reset token counters for the new session
        new_session = %{
          new_session
          | total_prompt_tokens: 0,
            total_completion_tokens: 0,
            total_tokens: 0
        }

        # Extract the original system message
        [%{role: "system", content: original_system_message}] = new_session.messages

        # Create a combined system message with the original prompt and summary
        combined_system_message = %{
          role: "system",
          content:
            "System: #{original_system_message}\n\nPrevious Session Summary:\n#{validated_summary}"
        }

        # Replace the system message in the new session
        new_session = %{new_session | messages: [combined_system_message]}

        # Log the combined system message to the new session
        log(new_session, combined_system_message)

        Beamcore.Agent.Core.StatusBar.update(pid, new_session)

        Beamcore.Agent.Core.Pretty.print_assistant(
          "Session rolled over successfully. New session ID: #{new_session.session_id}",
          :main
        )

        new_session

      {:error, reason} ->
        Beamcore.Agent.Core.Pretty.print_error("Failed to summarize session: #{inspect(reason)}")
        # If it fails, return the old session
        %{session | messages: messages}
    end
  end

  @doc """
  Trims and cleans a message list before it is sent to the summarizer.
  Ensures it is under the token/character threshold and conforms to message alternation requirements.
  """
  def trim_and_clean_messages(messages, limit \\ 30) do
    # 1. Separate system messages and others
    {system_messages, other_messages} =
      Enum.split_with(messages, fn m ->
        (m[:role] || m["role"]) == "system"
      end)

    # 2. Truncate content of all messages to 4000 chars to avoid huge payloads
    truncated_messages = Enum.map(other_messages, &truncate_message_content/1)

    # 3. Take the last `limit` messages
    trimmed_messages = Enum.take(truncated_messages, -limit)

    # 4. Clean up orphaned tools
    cleaned_messages = clean_orphaned_tools(trimmed_messages)

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

  defp truncate_for_api(message) do
    role = message[:role] || message["role"]
    content = message[:content] || message["content"]

    max_chars =
      case role do
        "system" -> @max_system_chars
        "tool" -> @max_tool_result_chars
        "assistant" -> @max_assistant_chars
        "user" -> @max_user_chars
        _ -> @max_other_chars
      end

    if is_binary(content) and String.length(content) > max_chars do
      put_message_content(message, compact_content(content, max_chars))
    else
      message
    end
  end

  defp compact_tool_calls(message) do
    case message[:tool_calls] || message["tool_calls"] do
      tool_calls when is_list(tool_calls) ->
        put_tool_calls(message, Enum.map(tool_calls, &compact_tool_call/1))

      _other ->
        message
    end
  end

  defp compact_tool_call(tool_call) do
    function = tool_call[:function] || tool_call["function"]

    if is_map(function) do
      arguments = function[:arguments] || function["arguments"]
      compacted_arguments = compact_tool_arguments(arguments)
      compacted_function = put_map_value(function, "arguments", compacted_arguments)
      put_map_value(tool_call, "function", compacted_function)
    else
      tool_call
    end
  end

  defp compact_tool_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> Enum.into(%{}, fn {key, value} -> {key, compact_tool_arg(key, value)} end)
        |> Jason.encode!()

      _ ->
        arguments
    end
  end

  defp compact_tool_arguments(arguments), do: arguments

  defp compact_tool_arg(key, value)
       when key in @large_tool_arg_keys and is_binary(value) do
    if String.length(value) > @max_tool_arg_chars do
      "[#{key} omitted: #{String.length(value)} chars, #{line_count(value)} lines]"
    else
      value
    end
  end

  defp compact_tool_arg(_key, value), do: value

  defp put_tool_calls(message, tool_calls) do
    if Map.has_key?(message, :tool_calls) do
      Map.put(message, :tool_calls, tool_calls)
    else
      Map.put(message, "tool_calls", tool_calls)
    end
  end

  defp put_map_value(map, key, value) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(map, atom_key) -> Map.put(map, atom_key, value)
      true -> Map.put(map, key, value)
    end
  rescue
    ArgumentError -> Map.put(map, key, value)
  end

  defp line_count(value), do: value |> String.split("\n") |> length()

  defp compact_content(
         content,
         max_chars,
         marker \\ "\n... [content compacted; middle omitted] ...\n"
       ) do
    marker_size = String.length(marker)
    budget = max(max_chars - marker_size, 0)
    head_size = div(budget, 2)
    tail_size = budget - head_size

    String.slice(content, 0, head_size) <> marker <> String.slice(content, -tail_size, tail_size)
  end

  defp put_message_content(message, content) do
    if Map.has_key?(message, :content) do
      Map.put(message, :content, content)
    else
      Map.put(message, "content", content)
    end
  end

  defp truncate_message_content(message) do
    content = message[:content] || message["content"]

    cond do
      is_binary(content) and String.length(content) > 4000 ->
        put_message_content(
          message,
          compact_content(content, 4000, "\n... [content truncated for summarization] ...\n")
        )

      true ->
        message
    end
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
    Enum.drop_while(messages, fn msg ->
      (msg[:role] || msg["role"]) != "user"
    end)
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
