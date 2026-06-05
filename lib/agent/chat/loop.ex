defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{
    API,
    Commands,
    Context,
    CorrectionCatch,
    MultilineInput,
    Session,
    ToolPolicy
  }

  alias Beamcore.Agent.Core.{Pretty, StatusBar}
  alias Beamcore.Agent.Tools.Dispatcher

  require Logger

  @max_tool_depth 100
  @event_content_limit 1_200
  @event_content_head 420
  @event_content_tail 260

  @doc """
  Start the chat loop with the given session and status bar PID.
  """
  def start(session, pid) do
    loop(session, pid)
  end

  defp loop(session, pid) do
    Pretty.print_prompt()

    case IO.gets("") do
      :eof ->
        StatusBar.reset(pid)
        IO.puts("\nGoodbye!")

      input when is_binary(input) ->
        case String.trim(input) do
          "" ->
            loop(session, pid)

          "/" <> command ->
            handle_command(command, session, pid)

          "<<<" ->
            handle_paste(session, pid, ">>>")

          trimmed ->
            new_session = send_message(session, trimmed, pid)
            loop(new_session, pid)
        end

      _ ->
        :ok
    end
  end

  defp handle_command("paste", session, pid), do: handle_paste(session, pid, "/end")

  defp handle_command(command, session, pid) do
    case Commands.execute(command, session) do
      {:run_pending, confirmed_session, content, policy} ->
        confirmed_session
        |> send_message(content, pid, policy)
        |> Session.clear_pending_action()
        |> loop(pid)

      {:login_prompt, session} ->
        handle_login_prompt(session, pid)

      new_session ->
        loop(new_session, pid)
    end
  end

  defp handle_login_prompt(session, pid) do
    case IO.gets("Mistral API key: ") do
      input when is_binary(input) ->
        session =
          case Commands.store_login_token(input) do
            :ok ->
              IO.puts(Commands.login_saved_message())
              %{session | client: Beamcore.OpenAI.client()}

            {:error, :empty_value} ->
              IO.puts("Login token was empty; nothing was saved.")
              session
          end

        loop(session, pid)

      _ ->
        IO.puts("Login canceled.")
        loop(session, pid)
    end
  end

  defp handle_paste(session, pid, terminator) do
    IO.puts("Paste multi-line input. Finish with #{terminator}.")

    case collect_paste([], terminator) do
      {:ok, text} ->
        session
        |> send_message(text, pid)
        |> loop(pid)

      {:error, :empty} ->
        Beamcore.Agent.Core.Pretty.print_error("Empty paste ignored.")
        loop(session, pid)
    end
  end

  defp collect_paste(lines, terminator) do
    case IO.gets("") do
      :eof ->
        lines
        |> MultilineInput.collect_until(terminator)
        |> eof_paste_result()

      input when is_binary(input) ->
        line = String.trim_trailing(input, "\n") |> String.trim_trailing("\r")

        case MultilineInput.collect_until(lines ++ [line], terminator) do
          {:ok, text, _rest} -> {:ok, text}
          {:error, :empty, _rest} -> {:error, :empty}
          {:more, _text} -> collect_paste(lines ++ [line], terminator)
        end
    end
  end

  defp eof_paste_result({:ok, text, _rest}), do: {:ok, text}
  defp eof_paste_result({:error, :empty, _rest}), do: {:error, :empty}

  defp eof_paste_result({:more, text}) do
    if String.trim(text) == "", do: {:error, :empty}, else: {:ok, String.trim(text)}
  end

  def send_message(session, content, pid, policy_override \\ nil, opts \\ []) do
    with {:ok, session} <- ensure_client(session, opts) do
      do_send_message(session, content, pid, policy_override, opts)
    else
      {:error, session} -> session
    end
  end

  defp ensure_client(%{client: nil} = session, opts) do
    try do
      {:ok, %{session | client: Beamcore.OpenAI.client()}}
    rescue
      error in Beamcore.OpenAI.MissingConfigError ->
        message = Exception.message(error)
        maybe_print(opts, fn -> Pretty.print_error(message) end)
        emit(opts, {:error, message})
        {:error, session}
    end
  end

  defp ensure_client(session, _opts), do: {:ok, session}

  defp do_send_message(session, content, pid, policy_override, opts) do
    session =
      if session.project_policy_bypassed? do
        Session.clear_project_policy_block_history(session)
      else
        session
      end

    policy =
      policy_override
      |> Kernel.||(session.policy_override)
      |> Kernel.||(ToolPolicy.from_user_message(content))
      |> apply_session_project_policy_bypass(session)

    emit(opts, {:status, :thinking})

    session =
      if ToolPolicy.confirmation_required?(policy) do
        %{session | pending_user_message: content}
      else
        %{session | pending_user_message: nil}
      end

    context =
      if ToolPolicy.project_policy_bypassed?(policy) do
        Context.clear_policy_blocks(session.context)
      else
        session.context
      end

    session = %{session | context: Context.from_user_request(context, content, policy)}
    user_message = %{role: "user", content: content}
    Session.log(session, user_message)

    messages = session.messages ++ [user_message]

    {messages, session} =
      Beamcore.Agent.Chat.SearchConductor.preflight(session, messages, content, policy, opts)

    process_messages(session, messages, pid, 0, policy, opts)
  end

  defp apply_session_project_policy_bypass(policy, %{project_policy_bypassed?: true}) do
    Map.put(policy, :project_policy_bypassed?, true)
  end

  defp apply_session_project_policy_bypass(policy, _session), do: policy

  defp process_messages(session, messages, _pid, depth, _policy, opts)
       when depth >= @max_tool_depth do
    warning = "Tool loop depth limit (#{@max_tool_depth}) reached. Stopping."
    maybe_print(opts, fn -> Pretty.print_warning(warning) end)
    emit(opts, {:error, warning})

    session = %{session | messages: Session.compact_history(messages)}
    finish_turn(session, opts)
  end

  defp process_messages(session, messages, pid, depth, policy, opts) do
    tools = Dispatcher.tool_specs(policy)

    api_messages =
      messages
      |> Session.prepare_for_api(session.context, 24)
      |> inject_policy_message(policy, tools)

    case API.execute(session.client, api_messages, tools, :main,
           silent: Keyword.get(opts, :silent, false),
           retry_config: Keyword.get(opts, :retry_config)
         ) do
      {:ok, %{message: message, raw_response: raw_response}} ->
        Session.log(session, Session.compact_raw_response(raw_response))

        maybe_print(opts, fn ->
          Pretty.print_assistant(message["content"], :main)
          Pretty.print_raw_response(raw_response)
        end)

        emit_assistant(opts, message["content"])

        session =
          if usage = raw_response["usage"] do
            Session.update_usage(session, usage)
          else
            session
          end

        if pid, do: StatusBar.update(pid, session)
        emit(opts, {:session, session})

        # --- Grace period logic ---
        # Hard limit: force rollover immediately, even mid-tool-chain
        if Session.needs_rollover_now?(session) do
          rolled_session = Session.summarize_and_rollover(session, messages ++ [message], pid)
          finish_turn(rolled_session, opts)
        else
          message = normalize_tool_calls(message)
          compacted_message = Session.compact_for_api(message)
          new_messages = messages ++ [compacted_message]

          case CorrectionCatch.stuck?(new_messages) do
            {true, reason} ->
              maybe_print(opts, fn ->
                Pretty.print_warning("⚠️ Loop detected: #{reason}")
              end)

              rolled_session =
                CorrectionCatch.correct_and_rollover(session, new_messages, reason, pid)

              continue_prompt =
                "⚠️ SYSTEM INTERRUPT: A mechanical loop was detected (#{reason}). " <>
                  "The session has been compacted with a diagnosis. " <>
                  "Follow the corrected plan — do NOT repeat the previous approach."

              send_message(rolled_session, continue_prompt, pid, nil, opts)

            false ->
              if has_tool_calls?(message) do
                # Agent has more work to do — continue the tool chain.
                # Even if needs_compaction is true, we let it finish.
                {tool_responses, session} =
                  Enum.map_reduce(message["tool_calls"], session, fn tool_call, session ->
                    name = tool_call["function"]["name"]
                    args = decode_tool_args(tool_call["function"]["arguments"])

                    emit(opts, {:tool_queued, name, args})
                    emit(opts, {:status, :tool_running})
                    emit(opts, {:tool_running, name, args})

                    content = Dispatcher.execute(name, args, policy)
                    maybe_print(opts, fn -> print_tool_execution(name, args, content) end)
                    event_content = compact_event_content(content)
                    emit(opts, {:tool_finished, name, args, event_content})
                    session = update_context(session, name, args, content)
                    emit(opts, {:session, session})

                    {
                      %{
                        role: "tool",
                        tool_call_id: tool_call["id"],
                        name: name,
                        content: content
                      },
                      session
                    }
                  end)

                Enum.each(tool_responses, &Session.log(session, &1))

                process_messages(
                  session,
                  new_messages ++ tool_responses,
                  pid,
                  depth + 1,
                  policy,
                  opts
                )
              else
                # Natural break — agent is done with tool calls, responding to user.
                # If compaction is needed, this is the moment to do it.
                if session.needs_compaction do
                  rolled_session = Session.summarize_and_rollover(session, new_messages, pid)
                  finish_turn(rolled_session, opts)
                else
                  session = %{session | messages: Session.compact_history(new_messages)}
                  finish_turn(session, opts)
                end
              end
          end
        end

      {:error, %OpenaiEx.Error{kind: :rate_limit} = error} ->
        message = Beamcore.Agent.Chat.RateLimit.message(error)
        maybe_print(opts, fn -> Pretty.print_rate_limit_error(error) end)
        emit(opts, {:error, message})
        emit(opts, {:status, :error})
        session

      {:error, %OpenaiEx.Error{kind: :api_timeout_error}} ->
        maybe_print(opts, &Pretty.print_timeout_error/0)
        emit(opts, {:error, "API request timed out. Retrying with longer timeout..."})
        emit(opts, {:status, :error})
        session

      {:error, %OpenaiEx.Error{} = error} ->
        maybe_print(opts, fn -> Pretty.print_api_error(error) end)
        emit(opts, {:error, api_error_text(error)})
        emit(opts, {:status, :error})
        session

      {:error, reason} ->
        message = "#{inspect(reason)}"
        maybe_print(opts, fn -> Pretty.print_error(message) end)
        emit(opts, {:error, message})
        emit(opts, {:status, :error})
        session
    end
  end

  defp maybe_print(opts, fun) do
    unless Keyword.get(opts, :silent, false), do: fun.()
  end

  defp finish_turn(session, opts) do
    emit(opts, {:session, session})
    emit(opts, {:status, :idle})
    session
  end

  defp emit(opts, event) do
    case Keyword.get(opts, :event_handler) do
      handler when is_function(handler, 1) ->
        try do
          handler.(event)
        rescue
          error ->
            log_emit_failure(event, Exception.message(error))
        catch
          kind, reason ->
            log_emit_failure(event, "#{inspect(kind)} #{inspect(reason)}")
        end

      nil ->
        :ok
    end
  end

  defp emit_assistant(opts, content) when is_binary(content) and content != "",
    do: emit(opts, {:assistant, content})

  defp emit_assistant(_opts, _content), do: :ok

  defp compact_event_content(content) when is_binary(content) do
    if String.length(content) <= @event_content_limit do
      content
    else
      char_count = String.length(content)
      line_count = line_count(content)
      omitted = max(char_count - @event_content_head - @event_content_tail, 0)
      head = String.slice(content, 0, @event_content_head)
      tail = String.slice(content, char_count - @event_content_tail, @event_content_tail)

      """
      #{head}

      [tool output omitted: #{omitted} chars omitted from #{char_count} chars, #{line_count} lines]

      #{tail}
      """
      |> String.trim()
    end
  end

  defp compact_event_content(content), do: inspect(content)

  defp line_count(""), do: 0
  defp line_count(content), do: content |> String.split("\n") |> length()

  defp log_emit_failure(event, reason) do
    Logger.debug(fn ->
      "TUI event handler failed for #{inspect(event_name(event))}: #{reason}"
    end)

    :ok
  end

  defp event_name(event) when is_tuple(event) and tuple_size(event) > 0, do: elem(event, 0)
  defp event_name(event), do: event

  defp api_error_text(error) do
    if error.message do
      if error.body,
        do: "#{error.message} | Body: #{inspect(error.body)}",
        else: "#{error.message}"
    else
      "API error (HTTP #{error.status_code || "unknown"})"
    end
  end

  defp normalize_tool_calls(%{"tool_calls" => tool_calls} = message) when is_list(tool_calls) do
    fixed_tool_calls =
      Enum.map(tool_calls, fn tool_call ->
        tool_call
        |> Map.put("type", "function")
        |> Map.delete("index")
      end)

    Map.put(message, "tool_calls", fixed_tool_calls)
  end

  defp normalize_tool_calls(message), do: message

  defp has_tool_calls?(%{"tool_calls" => tool_calls}) when is_list(tool_calls),
    do: tool_calls != []

  defp has_tool_calls?(_message), do: false

  defp inject_policy_message(messages, policy, tools) do
    policy_message = %{
      role: "system",
      content: policy_summary(policy, tools)
    }

    case messages do
      [system, context | rest] when is_map(system) and is_map(context) ->
        [system, context, policy_message | rest]

      [system | rest] when is_map(system) ->
        [system, policy_message | rest]

      other ->
        [policy_message | other]
    end
  end

  defp policy_summary(policy, tools) do
    tool_names =
      tools
      |> Enum.map(fn tool ->
        get_in(tool, [:function, :name]) || get_in(tool, ["function", "name"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    cond do
      ToolPolicy.project_policy_bypassed?(policy) ->
        "Current turn policy: freedom. Exposed tools: #{tool_names}. Project policy is bypassed for this session. Previous project-policy block messages are obsolete; retry the requested tool action directly instead of asking to update policy. Hard runtime safety still applies."

      Map.get(policy, :mode) == :unconfirmed ->
        "Current turn policy: legacy_unconfirmed. Exposed tools: #{tool_names}. Mutation tools are unavailable in this legacy compatibility mode."

      Map.get(policy, :mode) == :restricted_write ->
        allowed_paths = Enum.join(Map.get(policy, :allowed_write_paths, []), ", ")

        "Current turn policy: restricted_write. Exposed tools: #{tool_names}. Allowed write paths: #{allowed_paths}. Do not call plan."

      Map.get(policy, :mode) == :read_only ->
        "Current turn policy: read_only. Exposed tools: #{tool_names}. Do not call mutation or network tools."

      Map.get(policy, :mode) == :invalid_policy ->
        "Current turn policy: invalid_policy. Exposed tools: #{tool_names}. Mutation tools are disabled."

      true ->
        "Current turn policy: autonomous. Exposed tools: #{tool_names}. Act directly and self-correct from tool errors."
    end
  end

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_args), do: %{}

  defp update_context(session, name, args, content),
    do: %{session | context: Context.update_from_tool(session.context, name, args, content)}

  defp print_tool_execution(name, args, "Error: Tool call blocked" <> rest) do
    Pretty.print_blocked_tool_call(name, args, "Tool call blocked" <> rest)
  end

  defp print_tool_execution(name, args, "Error: Mutation requires" <> rest) do
    Pretty.print_blocked_tool_call(name, args, "Mutation requires" <> rest)
  end

  defp print_tool_execution(name, args, "Error: " <> reason) do
    Pretty.print_tool_call(name, args)
    Pretty.print_error(reason)
  end

  defp print_tool_execution(name, args, _content) do
    Pretty.print_tool_call(name, args)
  end
end
