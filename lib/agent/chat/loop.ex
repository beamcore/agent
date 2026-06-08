defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{
    API,
    Commands,
    Context,
    CorrectionCatch,
    ModeSettings,
    MultilineInput,
    Session,
    ToolPolicy
  }

  alias Beamcore.Agent.Core.{Pretty, StatusBar}
  alias Beamcore.Agent.Tools.Dispatcher

  require Logger

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
              session

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

  defp ensure_client(
         %{roles: %{primary: %{provider: _provider, model: _model}}} = session,
         _opts
       ),
       do: {:ok, session}

  defp ensure_client(%{client: nil} = session, opts) do
    message = Beamcore.Provider.Registry.missing_config_message()
    maybe_print(opts, fn -> Pretty.print_error(message) end)
    emit(opts, {:error, message})
    {:error, session}
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
    session = maybe_goal_checkpoint(session, content)

    {messages, session} =
      Beamcore.Agent.Chat.SearchConductor.preflight(session, messages, content, policy, opts)

    process_messages(session, messages, pid, 0, policy, opts)
  end

  defp apply_session_project_policy_bypass(policy, %{project_policy_bypassed?: true}) do
    Map.put(policy, :project_policy_bypassed?, true)
  end

  defp apply_session_project_policy_bypass(policy, _session), do: policy

  defp process_messages(session, messages, pid, depth, policy, opts)
       when depth >= 0 do
    max_depth = tool_depth_limit(session)

    if depth >= max_depth do
      stop_for_depth_limit(session, messages, opts, max_depth)
    else
      do_process_messages(session, messages, pid, depth, policy, opts)
    end
  end

  defp stop_for_depth_limit(session, messages, opts, max_depth) do
    warning = "Tool loop depth limit (#{max_depth}) reached. Stopping."
    maybe_print(opts, fn -> Pretty.print_warning(warning) end)
    emit(opts, {:error, warning})

    session =
      session
      |> Map.put(:messages, Session.compact_history(messages))
      |> Session.append_timeline(:interrupted, warning)
      |> Session.checkpoint("Stopped after tool depth limit.", %{tool_depth_limit: max_depth})

    finish_turn(session, opts)
  end

  defp do_process_messages(session, messages, pid, depth, policy, opts) do
    tools = Dispatcher.tool_specs(policy)
    settings = mode_settings(session)

    opts =
      case session.screen_type do
        :research -> Keyword.put_new(opts, :temperature, 0.0)
        :agent -> Keyword.put_new(opts, :temperature, 0.2)
        _ -> opts
      end

    session = maybe_research_stage(session, :researcher, "Researcher prepared bounded context.")

    api_messages =
      prepare_api_messages(session, messages, policy, tools, settings)

    session = maybe_research_stage(session, :synthesizer, "Synthesizer reviewed bounded context.")

    session =
      Session.append_timeline(session, :model_call, model_call_summary(session), %{
        role: model_call_role(session),
        title: model_call_title(session),
        metadata: %{
          provider: provider_name(session),
          model: model_name(session),
          depth: depth,
          approximate_input_tokens: Beamcore.Agent.Chat.Budget.estimate_tokens(api_messages)
        }
      })

    call_started = System.monotonic_time(:millisecond)

    api_result =
      API.execute(session.client, api_messages, tools, :main,
        selection: Beamcore.Provider.Selection.primary(session.roles),
        model: model_name(session),
        silent: Keyword.get(opts, :silent, false),
        retry_config: Keyword.get(opts, :retry_config) || retry_config(settings),
        temperature: Keyword.get(opts, :temperature)
      )

    call_elapsed = System.monotonic_time(:millisecond) - call_started

    case api_result do
      {:ok, %{message: message, raw_response: raw_response}} ->
        Session.log(session, Session.compact_raw_response(raw_response))

        {cleaned_content, reasoning} = API.extract_reasoning(message)

        maybe_print(opts, fn ->
          if reasoning && reasoning != "", do: Pretty.print_thinking(reasoning, :main)
          Pretty.print_assistant(cleaned_content, :main)
          Pretty.print_raw_response(raw_response)
        end)

        if reasoning && reasoning != "", do: emit(opts, {:thinking, reasoning})
        emit_assistant(opts, cleaned_content)

        session =
          if usage = raw_response["usage"] do
            Session.update_usage(session, usage)
          else
            session
          end

        session = Session.append_timeline(session, :checkpoint_saved, "Model response received.")

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

                    session = maybe_pre_tool_checkpoint(session, name, args)

                    content =
                      Beamcore.Agent.FilesystemJournal.with_context(
                        filesystem_context(session),
                        fn -> Dispatcher.execute(name, args, policy) end
                      )

                    maybe_print(opts, fn -> print_tool_execution(name, args, content) end)
                    event_content = compact_event_content(content)
                    emit(opts, {:tool_finished, name, args, event_content})

                    session =
                      session
                      |> update_context(name, args, content)
                      |> maybe_post_tool_checkpoint(name, args, content)
                      |> Session.append_timeline(:tool_call, "Tool #{name} completed.", %{
                        role: tool_role(session),
                        title: "Tool call: #{name}",
                        metadata: %{
                          tool: name,
                          result: event_content
                        }
                      })

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
        Session.append_timeline(session, :failed, message)

      {:error, %OpenaiEx.Error{kind: :api_timeout_error}} ->
        message = timeout_message(session, settings, call_elapsed)
        maybe_print(opts, fn -> Pretty.print_error(message) end)
        emit(opts, {:error, message})
        emit(opts, {:status, :error})

        Session.append_timeline(session, :failed, message,
          role: model_call_role(session),
          title: "Provider timeout",
          metadata: timeout_metadata(session, settings, call_elapsed)
        )

      {:error, %Beamcore.Provider.Error{} = error} ->
        maybe_print(opts, fn -> Pretty.print_error(error.message) end)
        emit(opts, {:error, error.message})
        emit(opts, {:status, :error})
        Session.append_timeline(session, :failed, error.message)

      {:error, %OpenaiEx.Error{} = error} ->
        maybe_print(opts, fn -> Pretty.print_api_error(error) end)
        emit(opts, {:error, api_error_text(error)})
        emit(opts, {:status, :error})
        Session.append_timeline(session, :failed, api_error_text(error))

      {:error, reason} ->
        message = "#{inspect(reason)}"
        maybe_print(opts, fn -> Pretty.print_error(message) end)
        emit(opts, {:error, message})
        emit(opts, {:status, :error})
        Session.append_timeline(session, :failed, message)
    end
  end

  defp prepare_api_messages(session, messages, policy, tools, settings) do
    messages
    |> Session.prepare_for_api(session.context, settings.history_limit, settings.input_budget)
    |> inject_research_harness(session)
    |> inject_policy_message(policy, tools)
    |> Beamcore.Agent.Chat.Budget.fit_messages(settings.input_budget)
  end

  defp mode_settings(%{mode_settings: %ModeSettings{} = settings}), do: settings
  defp mode_settings(%{screen_type: screen_type}), do: ModeSettings.resolve(screen_type)

  defp model_name(session) do
    case Beamcore.Provider.Selection.primary(session.roles) do
      %{model: model} -> model
      _ -> mode_settings(session).model
    end
  end

  defp provider_name(session) do
    case Beamcore.Provider.Selection.primary(session.roles) do
      %{provider: provider} -> provider
      _ -> mode_settings(session).provider
    end
  end

  defp tool_depth_limit(session) do
    settings = mode_settings(session)

    if ModeSettings.local_provider?(settings) do
      min(settings.tool_depth_limit, 6)
    else
      settings.tool_depth_limit
    end
  end

  defp retry_config(settings) do
    max_retries = if ModeSettings.local_provider?(settings), do: 0, else: settings.retry_limit

    %Beamcore.Retry.Config{
      max_retries: max_retries,
      initial_backoff: Beamcore.Agent.Chat.RateLimit.default_wait_ms(),
      max_backoff: Beamcore.Agent.Chat.RateLimit.default_wait_ms(),
      backoff_multiplier: 1,
      retryable_errors: [
        :rate_limit,
        :api_timeout_error,
        :api_connection_error,
        :internal_server_error
      ]
    }
  end

  defp maybe_research_stage(%{screen_type: :research} = session, role, summary) do
    case role do
      :researcher ->
        Beamcore.Agent.Research.DeepResearch.record_researcher_stage(session, summary)

      :synthesizer ->
        Beamcore.Agent.Research.DeepResearch.record_synthesizer_stage(session, summary)
    end
  end

  defp maybe_research_stage(session, _role, _summary), do: session

  defp model_call_role(%{screen_type: :research}), do: :synthesizer
  defp model_call_role(_session), do: :agent

  defp model_call_title(%{screen_type: :research}), do: "Synthesizer model call"
  defp model_call_title(%{screen_type: :chat}), do: "Chat model call"
  defp model_call_title(_session), do: "Agent model call"

  defp model_call_summary(%{screen_type: :research} = session),
    do: "Synthesizer called #{provider_name(session)}/#{model_name(session)}."

  defp model_call_summary(session),
    do: "Agent called #{provider_name(session)}/#{model_name(session)}."

  defp tool_role(%{screen_type: :research}), do: :researcher
  defp tool_role(_session), do: :agent

  defp maybe_goal_checkpoint(%{screen_type: :agent} = session, content) do
    Session.append_timeline(session, :decision, "F1 accepted goal: #{short_text(content)}",
      role: :user,
      title: "F1 goal accepted",
      metadata: %{mode: "F1 Dev"}
    )
  end

  defp maybe_goal_checkpoint(session, _content), do: session

  defp maybe_pre_tool_checkpoint(%{screen_type: :agent} = session, name, args)
       when name in ["modify_file", "fs", "image_generation"] do
    summary =
      if destructive_tool_call?(name, args) do
        "Before destructive filesystem mutation."
      else
        "Before filesystem mutation."
      end

    Session.append_timeline(session, :file_change, summary,
      role: :agent,
      title: "F1 filesystem checkpoint",
      metadata: %{
        mode: "F1 Dev",
        tool: name,
        operation: tool_operation(args),
        destructive: destructive_tool_call?(name, args),
        journal_position:
          Beamcore.Agent.FilesystemJournal.journal_position(session.workspace_root)
      }
    )
  end

  defp maybe_pre_tool_checkpoint(session, _name, _args), do: session

  defp maybe_post_tool_checkpoint(%{screen_type: :agent} = session, name, args, content)
       when name in ["modify_file", "fs", "image_generation"] do
    if tool_success?(content) do
      Session.append_timeline(session, :file_change, "After successful filesystem mutation.",
        role: :agent,
        title: "F1 mutation completed",
        metadata: %{
          mode: "F1 Dev",
          tool: name,
          operation: tool_operation(args),
          journal_position:
            Beamcore.Agent.FilesystemJournal.journal_position(session.workspace_root)
        }
      )
    else
      session
    end
  end

  defp maybe_post_tool_checkpoint(%{screen_type: :agent} = session, name, args, content)
       when name in ["test_tool", "git"] do
    if validation_tool_call?(name, args) do
      Session.append_timeline(session, :decision, "After validation.",
        role: :agent,
        title: "F1 validation completed",
        metadata: %{mode: "F1 Dev", tool: name, result: compact_event_content(content)}
      )
    else
      session
    end
  end

  defp maybe_post_tool_checkpoint(session, _name, _args, _content), do: session

  defp destructive_tool_call?("fs", args) do
    operation = tool_operation(args)
    operation in ["remove", "move"] or (operation == "copy" and Map.get(args, "force", false))
  end

  defp destructive_tool_call?("modify_file", args) do
    Map.get(args, "operation") == "create_file" and Map.get(args, "overwrite", false)
  end

  defp destructive_tool_call?(_name, _args), do: false

  defp validation_tool_call?("test_tool", _args), do: true
  defp validation_tool_call?("git", args), do: tool_operation(args) in ["status", "diff"]
  defp validation_tool_call?(_name, _args), do: false

  defp tool_success?(content) when is_binary(content) do
    not String.starts_with?(String.trim_leading(content), "Error:")
  end

  defp tool_success?(_), do: true

  defp tool_operation(args) when is_map(args) do
    Map.get(args, "operation") || Map.get(args, :operation) || Map.get(args, "command") ||
      Map.get(args, :command) || "unknown"
  end

  defp tool_operation(_args), do: "unknown"

  defp short_text(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 120)
  end

  defp short_text(_), do: ""

  defp filesystem_context(session) do
    %{
      session_id: session.session_id,
      branch_id: session.branch_id,
      checkpoint_id: session.active_checkpoint_id,
      generation_id: "turn-#{System.unique_integer([:positive, :monotonic])}",
      workspace_root: session.workspace_root
    }
  end

  defp timeout_message(session, settings, elapsed_ms) do
    role = model_call_role(session) |> to_string() |> String.capitalize()
    configured = receive_timeout_ms(settings)

    "#{role} timed out waiting for the complete non-streaming provider response after #{format_ms(elapsed_ms)}. Provider: #{provider_name(session)}. Model: #{model_name(session)}. Configured receive timeout: #{format_ms(configured)}."
  end

  defp timeout_metadata(session, settings, elapsed_ms) do
    %{
      role: model_call_role(session),
      provider: provider_name(session),
      model: model_name(session),
      stage: :model_call,
      timeout_type: :non_streaming_receive_timeout,
      configured_duration_ms: receive_timeout_ms(settings),
      elapsed_duration_ms: elapsed_ms,
      attempt_number: 1,
      max_attempts:
        if(ModeSettings.local_provider?(settings), do: 1, else: settings.retry_limit + 1),
      stream: false
    }
  end

  defp receive_timeout_ms(settings) do
    if ModeSettings.local_provider?(settings) do
      case System.get_env("BEAMCORE_LOCAL_PROVIDER_RECEIVE_TIMEOUT_MS") do
        value when is_binary(value) ->
          case Integer.parse(value) do
            {ms, ""} when ms > 0 -> ms
            _ -> Application.get_env(:agent, :local_provider_receive_timeout_ms, 120_000)
          end

        _ ->
          Application.get_env(:agent, :local_provider_receive_timeout_ms, 120_000)
      end
    else
      Application.get_env(:agent, :provider_receive_timeout_ms, 30_000)
    end
  end

  defp format_ms(ms) when is_integer(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(ms), do: "#{ms}ms"

  defp maybe_print(opts, fun) do
    unless Keyword.get(opts, :silent, false), do: fun.()
  end

  defp finish_turn(session, opts) do
    session = Session.append_timeline(session, :completed, "Turn completed.")
    emit(opts, {:session, session})
    emit(opts, {:status, :idle})

    if session.screen_type == :research do
      last_message = List.last(session.messages)
      content = last_message && (last_message[:content] || last_message["content"])

      if is_binary(content) and String.contains?(content, "RESEARCH_COMPLETE") do
        path = session.workspace_root
        emit(opts, {:assistant, "Research complete! Folder path: #{path}"})

        unless Keyword.get(opts, :silent, false) do
          Pretty.print_assistant("Research complete! Folder path: #{path}", :main)
        end
      end
    end

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

  defp inject_research_harness(messages, %{screen_type: :research} = session) do
    settings = mode_settings(session)

    Beamcore.Agent.Research.DeepResearch.prepare_messages(
      messages,
      session,
      settings.input_budget
    )
  end

  defp inject_research_harness(messages, _session), do: messages

  if Code.ensure_loaded?(Mix) and Mix.env() == :test do
    def test_inject_research_harness(messages, session) do
      inject_research_harness(messages, session)
    end
  end
end
