defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{
    API,
    ModeSettings,
    ModelPayload,
    Session
  }

  alias Beamcore.Agent.Tools.Dispatcher

  @repeated_tool_failure_limit 3

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
    messages = ensure_runtime_message(messages, tools)

    process_messages(session, messages, pid, 0, opts, nil)
  end

  defp process_messages(session, messages, pid, depth, opts, failure_guard) do
    tools = Dispatcher.tool_specs()
    settings = mode_settings(session)

    opts =
      case session.screen_type do
        :agent -> Keyword.put_new(opts, :temperature, 0.2)
        _ -> opts
      end

    {:ok, _api_messages, _estimate, metadata} =
      prepare_api_messages(session, messages)

    {session, messages} = Session.maybe_compact(session, messages, metadata, depth)

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
      depth: depth,
      failure_guard: failure_guard
    })
  end

  defp handle_api_result(api_result, session, messages, ctx) do
    %{
      pid: pid,
      opts: opts,
      settings: settings,
      call_elapsed: call_elapsed,
      depth: depth,
      failure_guard: failure_guard
    } = ctx

    case api_result do
      {:ok, %{message: message, raw_response: raw_response}} ->
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
        Session.log(session, message)
        new_messages = messages ++ [message]

        if has_tool_calls?(message) do
          tool_responses = execute_tools_parallel(message["tool_calls"], opts)

          failure_decision =
            advance_failure_guard(message["tool_calls"], tool_responses, failure_guard)

          tool_responses = maybe_add_recovery_guidance(tool_responses, failure_decision)

          Enum.each(tool_responses, &Session.log(session, &1))

          # Emit intermediate session with accumulated messages so TUI state
          # stays fresh. If the worker is interrupted (Ctrl+C), the TUI already
          # has the messages up to this tool-call round.
          all_messages = new_messages ++ tool_responses
          emit(opts, {:session, %{session | messages: all_messages}})

          case failure_decision do
            {:continue, next_guard} ->
              process_messages(
                session,
                all_messages,
                pid,
                depth + 1,
                opts,
                next_guard
              )

            {:recover, next_guard, tool_names} ->
              Beamcore.AppLog.warn("Repeated tool failure recovery requested",
                tools: Enum.join(tool_names, ", ")
              )

              emit(opts, {:status, :thinking})

              process_messages(
                session,
                all_messages,
                pid,
                depth + 1,
                opts,
                next_guard
              )

            {:stop, tool_names} ->
              stop_repeated_tool_failure(session, all_messages, tool_names, opts)
          end
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
    metadata = model_metadata(session)

    prepared =
      messages
      |> Session.prepare_for_api()
      |> ModelPayload.limit(metadata)

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
    Application.get_env(:beamcore, :provider_receive_timeout_ms, 30_000)
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

  @doc false
  def ensure_runtime_message(messages, tools) do
    runtime_message = %{
      role: "system",
      content: runtime_summary(tools)
    }

    {system_messages, conversation} =
      Enum.split_with(messages, &(message_role(&1) == "system"))

    stable_system = Enum.reject(system_messages, &runtime_message?/1)

    case stable_system do
      [primary | rest] -> [primary, runtime_message | rest] ++ conversation
      [] -> [runtime_message | conversation]
    end
  end

  defp runtime_message?(message) do
    message_role(message) == "system" and
      String.starts_with?(to_string(message_content(message)), "Exposed tools:")
  end

  defp message_role(message), do: message[:role] || message["role"]
  defp message_content(message), do: message[:content] || message["content"] || ""

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

  defp advance_failure_guard(tool_calls, tool_responses, previous) do
    signatures =
      tool_calls
      |> Enum.zip(tool_responses)
      |> Enum.map(fn {tool_call, response} -> failed_tool_signature(tool_call, response) end)

    if signatures != [] and Enum.all?(signatures, & &1) do
      fingerprint = signatures |> Enum.sort() |> :erlang.term_to_binary([:deterministic])

      count =
        case previous do
          %{fingerprint: ^fingerprint, count: count} -> count + 1
          _ -> 1
        end

      cond do
        count > @repeated_tool_failure_limit and previous[:recovery_prompted] ->
          names = signatures |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
          {:stop, names}

        count >= @repeated_tool_failure_limit ->
          names = signatures |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

          {:recover, %{fingerprint: fingerprint, count: count, recovery_prompted: true}, names}

        true ->
          {:continue, %{fingerprint: fingerprint, count: count}}
      end
    else
      {:continue, nil}
    end
  end

  defp maybe_add_recovery_guidance(tool_responses, {:recover, _guard, _tool_names}) do
    Enum.map(tool_responses, &add_recovery_guidance/1)
  end

  defp maybe_add_recovery_guidance(tool_responses, _decision), do: tool_responses

  defp add_recovery_guidance(response) do
    content = response[:content] || response["content"]

    guidance =
      "Automatic recovery required: this exact call has failed " <>
        "#{@repeated_tool_failure_limit} consecutive times. Continue autonomously without " <>
        "asking the user to repeat the request. Retry only if the failure is transient; " <>
        "otherwise change the arguments or approach."

    updated_content =
      case Jason.decode(content) do
        {:ok, %{"ok" => false} = failure} ->
          failure
          |> Map.put("automatic_recovery", true)
          |> Map.put("next_step", guidance)
          |> Jason.encode!()

        _ ->
          to_string(content) <> "\n\n" <> guidance
      end

    cond do
      Map.has_key?(response, :content) -> Map.put(response, :content, updated_content)
      true -> Map.put(response, "content", updated_content)
    end
  end

  defp failed_tool_signature(tool_call, response) do
    with content when is_binary(content) <- response[:content] || response["content"],
         {:ok, failure_class} <- tool_failure_class(content) do
      function = tool_call["function"] || %{}
      name = function["name"] || "unknown"
      args = decode_tool_args(function["arguments"])
      args_hash = :crypto.hash(:sha256, :erlang.term_to_binary(args, [:deterministic]))
      {name, args_hash, failure_class}
    else
      _ -> nil
    end
  end

  defp tool_failure_class(content) do
    case Jason.decode(content) do
      {:ok, %{"ok" => false} = failure} ->
        classification = failure["classification"] || failure["exit_code"] || "tool_error"
        {:ok, to_string(classification)}

      _ ->
        plain_tool_failure_class(content)
    end
  end

  defp plain_tool_failure_class("Tool execution timed out" <> _), do: {:ok, "timeout"}
  defp plain_tool_failure_class("Tool execution crashed" <> _), do: {:ok, "crash"}
  defp plain_tool_failure_class("Tool call failed" <> _), do: {:ok, "dispatcher_error"}
  defp plain_tool_failure_class("Function not implemented"), do: {:ok, "not_implemented"}
  defp plain_tool_failure_class(_content), do: :not_a_failure

  defp stop_repeated_tool_failure(session, messages, tool_names, opts) do
    names = Enum.join(tool_names, ", ")

    message =
      "Automatic recovery could not break the repeated failed #{names} call loop. " <>
        "The session is preserved; change the arguments or approach before retrying."

    Beamcore.AppLog.warn("Repeated tool failure stopped", tools: names)
    emit(opts, {:error, message})
    emit(opts, {:status, :error})

    session = %{session | messages: Session.compact_history(messages)}
    emit(opts, {:session, session})
    session
  end

  # --- Parallel tool execution ---

  @tool_timeout_ms :timer.minutes(5)

  defp execute_tools_parallel(tool_calls, opts) when length(tool_calls) <= 1 do
    Enum.map(tool_calls, &execute_single_tool(&1, opts))
  end

  defp execute_tools_parallel(tool_calls, opts) do
    event_handler = Process.get(:event_handler)

    # Emit all queued events from main process (preserves TUI ordering)
    Enum.each(tool_calls, fn tc ->
      name = tc["function"]["name"]
      args = decode_tool_args(tc["function"]["arguments"])
      emit(opts, {:tool_queued, name, args})
    end)

    emit(opts, {:status, :tool_running})

    # Fire all tool calls in parallel
    tasks =
      Enum.map(tool_calls, fn tool_call ->
        Task.async(fn ->
          # Copy event handler so Eeva's emit_preview works in worker processes
          if event_handler, do: Process.put(:event_handler, event_handler)
          execute_tool_call(tool_call)
        end)
      end)

    # Collect results as they complete (preserves original ordering)
    results = Task.yield_many(tasks, @tool_timeout_ms)

    Enum.zip(tool_calls, results)
    |> Enum.map(fn {tool_call, {task, result}} ->
      name = tool_call["function"]["name"]
      args = decode_tool_args(tool_call["function"]["arguments"])

      content =
        case result do
          {:ok, tool_response} ->
            tool_response

          nil ->
            Task.shutdown(task, :brutal_kill)
            "Tool execution timed out after #{@tool_timeout_ms}ms"

          {:exit, reason} ->
            "Tool execution crashed: #{inspect(reason)}"
        end

      emit(opts, {:tool_finished, name, args, content})

      %{
        role: "tool",
        tool_call_id: tool_call["id"],
        name: name,
        content: content
      }
    end)
  end

  defp execute_tool_call(tool_call) do
    name = tool_call["function"]["name"]
    args = decode_tool_args(tool_call["function"]["arguments"])
    Dispatcher.execute(name, args)
  end

  defp execute_single_tool(tool_call, opts) do
    name = tool_call["function"]["name"]
    args = decode_tool_args(tool_call["function"]["arguments"])

    emit(opts, {:tool_queued, name, args})
    emit(opts, {:status, :tool_running})
    emit(opts, {:tool_running, name, args})

    content = Dispatcher.execute(name, args)

    emit(opts, {:tool_finished, name, args, content})

    %{
      role: "tool",
      tool_call_id: tool_call["id"],
      name: name,
      content: content
    }
  end
end
