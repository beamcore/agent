defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{
    API,
    Context,
    ModeSettings,
    Session,
    ToolRuntime
  }

  alias Beamcore.Agent.Tools.Dispatcher

  require Logger

  @event_content_limit 1_200
  @event_content_head 420
  @event_content_tail 260

  def send_message(session, content, pid, runtime_caps \\ nil, opts \\ []) do
    with {:ok, session} <- ensure_client(session, opts) do
      do_send_message(session, content, pid, runtime_caps, opts)
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
    emit(opts, {:error, message})
    {:error, session}
  end

  defp ensure_client(session, _opts), do: {:ok, session}

  defp do_send_message(session, content, pid, runtime_caps, opts) do
    # Make the event handler available to tools (e.g., eeva preview) via process dict.
    case Keyword.get(opts, :event_handler) do
      handler when is_function(handler, 1) -> Process.put(:event_handler, handler)
      _ -> :ok
    end

    caps =
      runtime_caps
      |> Kernel.||(session.runtime_caps)
      |> Kernel.||(ToolRuntime.default())

    emit(opts, {:status, :thinking})

    session = %{session | context: Context.from_user_request(session.context, content, caps)}
    user_message = %{role: "user", content: content}
    Session.log(session, user_message)

    messages = session.messages ++ [user_message]
    session = maybe_goal_checkpoint(session, content)

    process_messages(session, messages, pid, 0, caps, opts)
  end

  defp process_messages(session, messages, pid, depth, caps, opts)
       when depth >= 0 do
    max_depth = tool_depth_limit(session)

    if depth >= max_depth do
      stop_for_depth_limit(session, messages, opts, max_depth)
    else
      do_process_messages(session, messages, pid, depth, caps, opts)
    end
  end

  defp stop_for_depth_limit(session, messages, opts, max_depth) do
    warning = "Tool loop depth limit (#{max_depth}) reached. Stopping."
    emit(opts, {:error, warning})

    session =
      session
      |> Map.put(:messages, Session.compact_history(messages))
      |> Session.append_timeline(:interrupted, warning)

    finish_turn(session, opts)
  end

  defp do_process_messages(session, messages, pid, depth, caps, opts) do
    if session.session_paused do
      emit(
        opts,
        {:error,
         "Session paused: context exceeds 200k tokens. Run /compress to compress the session before continuing."}
      )

      emit(opts, {:status, :idle})
      session
    else
      tools = Dispatcher.tool_specs(caps)
      settings = mode_settings(session)

      opts =
        case session.screen_type do
          :agent -> Keyword.put_new(opts, :temperature, 0.2)
          _ -> opts
        end

      with {:ok, api_messages, budget_plan, metadata} <-
             prepare_api_messages(session, messages, caps, tools, settings) do
        emit(opts, {:model_context, model_context_event(session, budget_plan, metadata)})

        session =
          Session.append_timeline(session, :model_call, model_call_summary(session), %{
            role: model_call_role(session),
            title: model_call_title(session),
            metadata:
              %{
                provider: provider_name(session),
                model: model_name(session),
                depth: depth
              }
              |> Map.merge(model_context_event(session, budget_plan, metadata)),
            checkpoint: false
          })

        call_started = System.monotonic_time(:millisecond)

        api_result =
          API.execute(session.client, api_messages, tools, :main,
            selection: Beamcore.Provider.Selection.primary(session.roles),
            model: model_name(session),
            silent: Keyword.get(opts, :silent, false),
            retry_config: Keyword.get(opts, :retry_config) || retry_config(settings, opts),
            temperature: Keyword.get(opts, :temperature),
            max_tokens: budget_plan.reserved_output_tokens,
            wait_fun: fn wait_ms ->
              sleep_before_retry(
                opts,
                :cooldown,
                wait_ms,
                "Provider is cooling down. Retrying automatically in #{format_ms(wait_ms)}."
              )
            end
          )

        call_elapsed = System.monotonic_time(:millisecond) - call_started

        handle_api_result(
          api_result,
          session,
          messages,
          message_context(pid, caps, opts, settings, call_elapsed, depth)
        )
      else
        {:error, budget_plan} ->
          message = context_budget_error(session, budget_plan)
          emit(opts, {:error, message})
          emit(opts, {:status, :error})

          Session.append_timeline(session, :failed, message,
            role: model_call_role(session),
            title: "Model context budget exceeded",
            metadata: budget_plan
          )
      end
    end
  end

  defp handle_api_result(api_result, session, messages, ctx) do
    %{
      pid: pid,
      caps: caps,
      opts: opts,
      settings: settings,
      call_elapsed: call_elapsed,
      depth: depth
    } = ctx

    case api_result do
      {:ok, %{message: message, raw_response: raw_response}} ->
        Session.log(session, raw_response)

        {cleaned_content, reasoning} = API.extract_reasoning(message)

        if reasoning && reasoning != "", do: emit(opts, {:thinking, reasoning})
        emit_assistant(opts, cleaned_content)

        usage = Beamcore.Provider.Usage.from_response(raw_response)
        emit(opts, {:provider_usage, Beamcore.Provider.Usage.to_safe_map(usage)})

        session =
          if usage.source == :provider_reported do
            Session.update_usage(session, usage)
          else
            session
          end

        session = Session.append_timeline(session, :checkpoint_saved, "Model response received.")

        emit(opts, {:session, session})

        # Emit warnings when context is getting large
        if session.session_paused do
          emit(
            opts,
            {:error,
             "Session paused: context exceeds 200k tokens. Run /compress to compress the session before continuing."}
          )
        else
          if session.warn_user do
            emit(
              opts,
              {:assistant,
               "Warning: context exceeds 150k tokens. Consider running /compress to compress the session."}
            )
          end
        end

        message = normalize_tool_calls(message)
        new_messages = messages ++ [message]

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

              content = Dispatcher.execute(name, args, caps)

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
                  },
                  checkpoint: false
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
            caps,
            opts
          )
        else
          # Natural break — agent is done with tool calls, responding to user.
          session = %{session | messages: Session.compact_history(new_messages)}
          finish_turn(session, opts)
        end

      {:error, %OpenaiEx.Error{kind: :rate_limit} = error} ->
        message = Beamcore.Agent.Chat.RateLimit.message(error)

        Beamcore.AppLog.warn("Rate limit hit",
          provider: provider_name(session),
          model: model_name(session),
          status_code: error.status_code,
          message: message
        )

        wait_ms =
          Beamcore.Agent.Chat.RateLimit.retry_after_ms(error) ||
            Beamcore.Agent.Chat.RateLimit.default_wait_ms()

        retry_message = "#{message} Retrying automatically in #{format_ms(wait_ms)}."
        sleep_before_retry(opts, :rate_limit, wait_ms, retry_message)
        process_messages(session, messages, pid, depth, caps, opts)

      {:error, %Beamcore.Provider.Error{kind: :rate_limit} = error} ->
        wait_ms = error.retry_after_ms || Beamcore.Agent.Chat.RateLimit.default_wait_ms()
        message = error.message || "Provider rate limit reached."

        Beamcore.AppLog.warn("Rate limit hit",
          provider: provider_name(session),
          model: model_name(session),
          kind: error.kind,
          message: message,
          retry_after_ms: wait_ms
        )

        retry_message = "#{message} Retrying automatically in #{format_ms(wait_ms)}."
        sleep_before_retry(opts, :rate_limit, wait_ms, retry_message)
        process_messages(session, messages, pid, depth, caps, opts)

      {:error, %OpenaiEx.Error{kind: :api_timeout_error}} ->
        message = timeout_message(session, settings, call_elapsed)

        Beamcore.AppLog.error("Provider timeout",
          provider: provider_name(session),
          model: model_name(session),
          elapsed_ms: call_elapsed,
          configured_timeout_ms: receive_timeout_ms(settings)
        )

        emit(opts, {:error, message})
        emit(opts, {:status, :error})

        Session.append_timeline(session, :failed, message,
          role: model_call_role(session),
          title: "Provider timeout",
          metadata: timeout_metadata(session, settings, call_elapsed)
        )

      {:error, %Beamcore.Provider.Error{} = error} ->
        Beamcore.AppLog.error("Provider error",
          provider: provider_name(session),
          model: model_name(session),
          kind: error.kind,
          message: error.message
        )

        emit(opts, {:error, error.message})
        emit(opts, {:status, :error})
        Session.append_timeline(session, :failed, error.message)

      {:error, %OpenaiEx.Error{} = error} ->
        Beamcore.AppLog.error("API error",
          provider: provider_name(session),
          model: model_name(session),
          status_code: error.status_code,
          message: error.message,
          body: error.body
        )

        emit(opts, {:error, api_error_text(error)})
        emit(opts, {:status, :error})
        Session.append_timeline(session, :failed, api_error_text(error))

      {:error, reason} ->
        message = "#{inspect(reason)}"

        Beamcore.AppLog.error("Unknown provider error",
          provider: provider_name(session),
          model: model_name(session),
          reason: message
        )

        emit(opts, {:error, message})
        emit(opts, {:status, :error})
        Session.append_timeline(session, :failed, message)
    end
  end

  defp message_context(pid, caps, opts, settings, call_elapsed, depth) do
    %{
      pid: pid,
      caps: caps,
      opts: opts,
      settings: settings,
      call_elapsed: call_elapsed,
      depth: depth
    }
  end

  defp prepare_api_messages(session, messages, caps, tools, settings) do
    prepared =
      messages
      |> Session.prepare_for_api(session.context, settings.history_limit, settings.input_budget)
      |> inject_runtime_message(caps, tools)

    metadata = model_metadata(session)

    case Beamcore.Agent.Chat.Budget.prepare_for_model(prepared, tools, metadata, settings) do
      {:ok, fitted, budget_plan} -> {:ok, fitted, budget_plan, metadata}
      {:error, budget_plan} -> {:error, budget_plan}
    end
  end

  defp model_metadata(session) do
    Beamcore.Provider.ModelMetadata.resolve(provider_name(session), model_name(session))
  end

  defp model_context_event(session, budget_plan, metadata) do
    budget_plan
    |> Map.take([
      :context_window,
      :context_source,
      :context_accuracy,
      :tokenizer,
      :estimated_input_tokens,
      :final_estimated_input_tokens,
      :reserved_output_tokens,
      :tool_schema_tokens,
      :safety_margin,
      :usable_input_budget,
      :budget_remaining,
      :compacted,
      :estimate_source
    ])
    |> Map.put(:provider, provider_name(session))
    |> Map.put(:model, model_name(session))
    |> Map.put(:metadata_source, metadata.source)
    |> Map.put(:metadata_accuracy, metadata.accuracy)
  end

  defp context_budget_error(session, budget_plan) do
    "Model context budget exceeded for #{provider_name(session)}/#{model_name(session)}. " <>
      "Estimated input #{budget_plan.final_estimated_input_tokens} tokens exceeds usable budget #{budget_plan.usable_input_budget} after compaction."
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
    session
    |> mode_settings()
    |> Map.fetch!(:tool_depth_limit)
  end

  defp retry_config(settings, opts) do
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
      ],
      sleep_fun: fn wait_ms ->
        sleep_before_retry(
          opts,
          :backoff,
          wait_ms,
          "Provider is temporarily unavailable. Retrying automatically in #{format_ms(wait_ms)}."
        )
      end
    }
  end

  defp sleep_before_retry(opts, reason, wait_ms, message) do
    wait_ms = max(wait_ms, 0)

    Beamcore.AppLog.warn("Provider retry scheduled",
      reason: reason,
      wait_ms: wait_ms
    )

    emit(opts, {:retry_wait, %{reason: reason, wait_ms: wait_ms, message: message}})
    Process.sleep(wait_ms)
    emit(opts, {:retry_resumed, %{reason: reason}})
    emit(opts, {:status, :thinking})

    Beamcore.AppLog.info("Provider retry resumed",
      reason: reason,
      wait_ms: wait_ms
    )
  end

  defp model_call_role(_session), do: :agent

  defp model_call_title(%{screen_type: :chat}), do: "Chat model call"
  defp model_call_title(_session), do: "Agent model call"

  defp model_call_summary(session),
    do: "Agent called #{provider_name(session)}/#{model_name(session)}."

  defp tool_role(_session), do: :agent

  defp maybe_goal_checkpoint(%{screen_type: :agent} = session, content) do
    Session.append_timeline(session, :decision, "F1 accepted goal: #{short_text(content)}",
      role: :user,
      title: "F1 goal accepted",
      metadata: %{mode: "F1 Dev"},
      checkpoint: false
    )
  end

  defp maybe_goal_checkpoint(session, _content), do: session

  defp maybe_pre_tool_checkpoint(%{screen_type: :agent} = session, "eeva", _args), do: session

  defp maybe_pre_tool_checkpoint(session, _name, _args), do: session

  defp maybe_post_tool_checkpoint(%{screen_type: :agent} = session, "eeva", _args, content) do
    if tool_success?(content) and filesystem_mutation?(content) do
      Session.append_timeline(session, :file_change, "After Eeva workspace mutation.",
        role: :agent,
        title: "F1 Eeva mutation completed",
        metadata: %{
          mode: "F1 Dev",
          tool: "eeva"
        }
      )
    else
      session
    end
  end

  defp maybe_post_tool_checkpoint(session, _name, _args, _content), do: session

  defp filesystem_mutation?(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"filesystem_changes" => %{"changed_path_count" => count}}}
      when is_integer(count) and count > 0 ->
        true

      _ ->
        false
    end
  end

  defp filesystem_mutation?(_content), do: false

  defp tool_success?(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"ok" => false}} -> false
      _ -> not String.starts_with?(String.trim_leading(content), "Error:")
    end
  end

  defp tool_success?(_), do: true

  defp short_text(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 120)
  end

  defp short_text(_), do: ""

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

  defp finish_turn(session, opts) do
    session = Session.append_timeline(session, :completed, "Turn completed.", checkpoint: false)
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

  defp inject_runtime_message(messages, caps, tools) do
    runtime_message = %{
      role: "system",
      content: runtime_summary(caps, tools)
    }

    case messages do
      [system, context | rest] when is_map(system) and is_map(context) ->
        [system, context, runtime_message | rest]

      [system | rest] when is_map(system) ->
        [system, runtime_message | rest]

      other ->
        [runtime_message | other]
    end
  end

  defp runtime_summary(_caps, tools) do
    tool_names =
      tools
      |> Enum.map(fn tool ->
        get_in(tool, [:function, :name]) || get_in(tool, ["function", "name"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "Exposed tools: #{tool_names}. Act directly in the trusted local runtime and self-correct from tool errors."
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
end
