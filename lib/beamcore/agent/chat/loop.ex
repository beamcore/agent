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

  defp log_debug(msg) do
    File.write!("/tmp/beamcore_stream.log", "[" <> inspect(DateTime.utc_now()) <> "] " <> msg <> "\n", [:append])
  rescue
    _ -> :ok
  end

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

    {:ok, _api_messages, _estimate, metadata} =
      prepare_api_messages(session, messages)

    {session, messages} = Session.maybe_compact(session, messages, metadata, depth)

    {:ok, api_messages, estimate, metadata} =
      prepare_api_messages(session, messages)

    emit(opts, {:model_context, model_context_event(session, estimate, metadata)})

    call_started = System.monotonic_time(:millisecond)

    selection = Beamcore.Provider.Selection.primary(session.roles)
    log_debug("[LOOP] process_messages, selection=#{inspect(selection)}")

    api_result =
      if selection && match?(%{provider: _}, selection) do
        log_debug("[LOOP] taking streaming path")
        stream_opts = [
          selection: selection,
          model: model_name(session),
          silent: Keyword.get(opts, :silent, false),
          retry_config: Keyword.get(opts, :retry_config) || retry_config(settings, opts),
          temperature: Keyword.get(opts, :temperature),
          max_tokens: metadata.max_output_tokens,
          receiver: self(),
          wait_fun: fn wait_ms ->
            sleep_before_retry(
              opts,
              :cooldown,
              wait_ms,
              "Provider is cooling down. Retrying automatically in #{format_ms(wait_ms)}."
            )
          end
        ]

        case API.execute_stream(session.client, api_messages, tools, stream_opts) do
          {:ok, ref} when is_reference(ref) ->
            log_debug("[LOOP] stream returned ref=#{inspect(ref)}")
            Process.put(:streamed, true)
            emit(opts, {:status, :streaming})
            stream_receive_loop(opts, %{content: "", reasoning: "", tool_calls: %{}, raw_response: nil, finish_reason: nil, thinking_emitted: false})

          # Non-streaming fallback (execute_stream fell back to execute)
          {:ok, %{message: _, raw_response: _}} = result ->
            log_debug("[LOOP] stream fell back to non-streaming")
            result

          {:error, reason} ->
            {:error, reason}
        end
      else
        log_debug("[LOOP] no provider selection, using non-streaming API.execute")
        API.execute(session.client, api_messages, tools,
          selection: selection,
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
      end

    call_elapsed = System.monotonic_time(:millisecond) - call_started

    handle_api_result(api_result, session, messages, %{
      pid: pid,
      opts: opts,
      settings: settings,
      call_elapsed: call_elapsed,
      depth: depth,
      streamed: true
    })
  end

  # --- Streaming receive loop ---

  defp stream_receive_loop(opts, acc) do
    log_debug("[STREAM] loop waiting, acc.content_len=#{String.length(acc.content || "")}")

    receive do
      {:stream_chunk, chunk} ->
        log_debug("[STREAM] got chunk: #{inspect(Map.keys(chunk))}")
        acc = accumulate_chunk(chunk, acc)

        # Emit content delta to TUI for real-time display
        {content_delta, _reasoning_delta} = extract_delta_content(chunk)

        # Emit thinking before first content delta so it appears above the response
        acc = if content_delta && content_delta != "" && !acc.thinking_emitted && acc.reasoning && acc.reasoning != "" do
          emit(opts, {:thinking, acc.reasoning})
          %{acc | thinking_emitted: true}
        else
          acc
        end

        if content_delta && content_delta != "",
          do: emit(opts, {:stream_delta, content_delta})

        stream_receive_loop(opts, acc)

      {:stream_done, _task_pid} ->
        log_debug("[STREAM] done, total content length=#{String.length(acc.content || "")}")
        if !acc.thinking_emitted && acc.reasoning && acc.reasoning != "",
          do: emit(opts, {:thinking, acc.reasoning})
        emit(opts, {:stream_done, acc.content})
        assemble_stream_result(acc)

      {:stream_error, reason, _task_pid} ->
        log_debug("[STREAM] error: #{inspect(reason)}")
        {:error, reason}

      other ->
        log_debug("[STREAM] unexpected message: #{inspect(other)}")
        stream_receive_loop(opts, acc)
    after
      120_000 ->
        log_debug("[STREAM] timeout")
        {:error, :stream_timeout}
    end
  end

  defp extract_delta_content(chunk) when is_map(chunk) do
    choices = chunk["choices"] || []
    case choices do
      [%{"delta" => delta} | _] ->
        content = delta["content"]
        reasoning = delta["reasoning_content"]
        {content, reasoning}
      _ ->
        {nil, nil}
    end
  end

  defp extract_delta_content(_), do: {nil, nil}

  defp accumulate_chunk(chunk, acc) when is_map(chunk) do
    choices = chunk["choices"] || []

    acc =
      case choices do
        [%{"delta" => delta} | _] ->
          # Accumulate text content
          content = acc.content <> (delta["content"] || "")

          # Accumulate reasoning content
          reasoning = (acc[:reasoning] || "") <> (delta["reasoning_content"] || "")

          # Accumulate tool calls
          tool_calls =
            case delta["tool_calls"] do
              tc_deltas when is_list(tc_deltas) ->
                Enum.reduce(tc_deltas, acc.tool_calls, fn tc_delta, tcs ->
                  idx = tc_delta["index"]
                  existing = Map.get(tcs, idx, %{"index" => idx, "function" => %{"name" => "", "arguments" => ""}})

                  updated =
                    existing
                    |> maybe_put("id", tc_delta["id"])
                    |> update_in(["function"], fn fn_map ->
                      fn_map
                      |> maybe_put("name", get_in(tc_delta, ["function", "name"]))
                      |> maybe_append("arguments", get_in(tc_delta, ["function", "arguments"]))
                    end)

                  Map.put(tcs, idx, updated)
                end)

              _ ->
                acc.tool_calls
            end

          # Track finish reason
          finish_reason =
            case List.first(choices) do
              %{"finish_reason" => fr} when fr != nil -> fr
              _ -> acc[:finish_reason]
            end

          %{acc | content: content, reasoning: reasoning, tool_calls: tool_calls, finish_reason: finish_reason}

        _ ->
          acc
      end

    # Capture usage from the final chunk
    case Map.get(chunk, "usage") do
      usage when is_map(usage) -> %{acc | raw_response: chunk}
      _ -> acc
    end
  end

  defp accumulate_chunk(_chunk, acc), do: acc

  defp assemble_stream_result(acc) do
    tool_calls =
      acc.tool_calls
      |> Map.values()
      |> Enum.sort_by(& &1["index"])

    message =
      if acc.content != "" do
        %{"role" => "assistant", "content" => acc.content}
      else
        %{"role" => "assistant", "content" => ""}
      end

    message =
      if tool_calls != [] do
        Map.put(message, "tool_calls", tool_calls)
      else
        message
      end

    raw_response = acc.raw_response || %{"choices" => [%{"message" => message}]}
    {:ok, %{message: message, raw_response: raw_response}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_append(map, _key, nil), do: map
  defp maybe_append(map, key, value) do
    Map.update(map, key, value, &(&1 <> value))
  end

  defp handle_api_result(api_result, session, messages, ctx) do
    %{
      pid: pid,
      opts: opts,
      settings: settings,
      call_elapsed: call_elapsed,
      depth: depth
    } = ctx

    streamed = Process.delete(:streamed) || false

    case api_result do
      {:ok, %{message: message, raw_response: raw_response}} ->
        {cleaned_content, reasoning} = API.extract_reasoning(message)

        if reasoning && reasoning != "", do: emit(opts, {:thinking, reasoning})
        unless streamed, do: emit_assistant(opts, cleaned_content)

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
