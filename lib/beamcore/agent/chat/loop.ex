defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{
    API,
    ModeSettings,
    Session
  }

  alias Beamcore.Agent.Tools.Dispatcher

  def send_message(session, content, pid, opts \\ []) do
    with {:ok, session} <- ensure_client(session, opts) do
      do_send_message(session, content, pid, opts)
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

  defp do_send_message(session, content, pid, opts) do
    # Make the event handler available to tools (e.g., eeva preview) via process dict.
    case Keyword.get(opts, :event_handler) do
      handler when is_function(handler, 1) -> Process.put(:event_handler, handler)
      _ -> :ok
    end


    emit(opts, {:status, :thinking})

    user_message = %{role: "user", content: content}
    Session.log(session, user_message)

    tools = Dispatcher.tool_specs()
    messages = session.messages ++ [user_message]
    messages = inject_runtime_message(messages, tools)

    process_messages(session, messages, pid, 0, opts)
  end

  defp process_messages(session, messages, pid, depth, opts) do
    tools = Dispatcher.tool_specs()
    settings = mode_settings(session)

    opts =
      case session.screen_type do
        :agent -> Keyword.put_new(opts, :temperature, 0.2)
        _ -> opts
      end

    {:ok, api_messages, estimate, metadata} =
      prepare_api_messages(session, messages)

    emit(opts, {:model_context, model_context_event(session, estimate, metadata)})

    call_started = System.monotonic_time(:millisecond)

    api_result =
      API.execute(session.client, api_messages, tools,
        selection: Beamcore.Provider.Selection.primary(session.roles),
        model: model_name(session),
        silent: Keyword.get(opts, :silent, false),
        retry_config: Keyword.get(opts, :retry_config) || retry_config(settings, opts),
        temperature: Keyword.get(opts, :temperature),
        max_tokens: metadata.max_output_tokens,
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

    handle_api_result(api_result, session, messages, %{
      pid: pid,
      opts: opts,
      settings: settings,
      call_elapsed: call_elapsed,
      depth: depth
    })
  end

  defp handle_api_result(api_result, session, messages, ctx) do
    %{
      pid: pid,
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

        emit(opts, {:session, session})

        message = normalize_tool_calls(message)
        new_messages = messages ++ [message]

        if has_tool_calls?(message) do
          {tool_responses, session} =
            Enum.map_reduce(message["tool_calls"], session, fn tool_call, session ->
              name = tool_call["function"]["name"]
              args = decode_tool_args(tool_call["function"]["arguments"])

              emit(opts, {:tool_queued, name, args})
              emit(opts, {:status, :tool_running})
              emit(opts, {:tool_running, name, args})

              content = Dispatcher.execute(name, args)

              emit(opts, {:tool_finished, name, args, content})

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

          # Emit intermediate session with accumulated messages so TUI state
          # stays fresh. If the worker is interrupted (Ctrl+C), the TUI already
          # has the messages up to this tool-call round.
          all_messages = new_messages ++ tool_responses
          emit(opts, {:session, %{session | messages: all_messages}})

          process_messages(
            session,
            all_messages,
            pid,
            depth + 1,
            opts
          )
        else
          # Natural break — agent is done with tool calls, responding to user.
          session = %{session | messages: Session.compact_history(new_messages)}
          finish_turn(session, opts)
        end

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
        session

      {:error, %Beamcore.Provider.Error{} = error} ->
        Beamcore.AppLog.error("Provider error",
          provider: provider_name(session),
          model: model_name(session),
          kind: error.kind,
          message: error.message
        )

        emit(opts, {:error, error.message})
        emit(opts, {:status, :error})
        session

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
        session

      {:error, reason} ->
        message = "#{inspect(reason)}"

        Beamcore.AppLog.error("Unknown provider error",
          provider: provider_name(session),
          model: model_name(session),
          reason: message
        )

        emit(opts, {:error, message})
        emit(opts, {:status, :error})
        session
    end
  end

  defp prepare_api_messages(session, messages) do
    prepared =
      messages
      |> Session.prepare_for_api()

    metadata = model_metadata(session)
    estimate = Beamcore.Agent.Chat.Budget.estimate_tokens(prepared)

    {:ok, prepared, estimate, metadata}
  end

  defp model_metadata(session) do
    Beamcore.Provider.ModelMetadata.resolve(provider_name(session), model_name(session))
  end

  defp model_context_event(session, estimate, metadata) do
    %{
      estimated_input_tokens: estimate,
      context_window: metadata.context_window,
      context_source: metadata.source,
      context_accuracy: metadata.accuracy,
      provider: provider_name(session),
      model: model_name(session)
    }
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

  defp retry_config(settings, opts) do
    %Beamcore.Retry.Config{
      max_retries: settings.retry_limit,
      initial_backoff: Beamcore.Retry.default_initial_backoff(),
      max_backoff: Beamcore.Retry.default_max_backoff(),
      backoff_multiplier: Beamcore.Retry.default_backoff_multiplier(),
      retryable_errors: Beamcore.Retry.default_retryable_errors(),
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
    wait_ms = (wait_ms && max(wait_ms, 0)) || 0

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

  defp timeout_message(session, settings, elapsed_ms) do
    configured = receive_timeout_ms(settings)

    "Agent timed out waiting for the complete non-streaming provider response after #{format_ms(elapsed_ms)}. Provider: #{provider_name(session)}. Model: #{model_name(session)}. Configured receive timeout: #{format_ms(configured)}."
  end

  defp receive_timeout_ms(_settings) do
    Application.get_env(:agent, :provider_receive_timeout_ms, 30_000)
  end

  defp format_ms(ms) when is_integer(ms) and ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(ms), do: "#{ms}ms"

  defp finish_turn(session, opts) do
    emit(opts, {:session, session})
    emit(opts, {:status, :idle})

    session
  end

  defp emit(opts, event) do
    case Keyword.get(opts, :event_handler) do
      handler when is_function(handler, 1) -> handler.(event)
      nil -> :ok
    end
  end

  defp emit_assistant(opts, content) when is_binary(content) and content != "",
    do: emit(opts, {:assistant, content})

  defp emit_assistant(_opts, _content), do: :ok

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

  defp inject_runtime_message(messages, tools) do
    runtime_message = %{
      role: "system",
      content: runtime_summary(tools)
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

  defp runtime_summary(tools) do
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
end
