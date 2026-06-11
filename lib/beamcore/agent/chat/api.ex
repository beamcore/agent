defmodule Beamcore.Agent.Chat.API do
  @moduledoc """
  Handles API calls to the OpenAI-compatible endpoint.
  """
  alias Beamcore.Retry.Config

  @completions_module Application.compile_env(
                        :agent,
                        :completions_module,
                        OpenaiEx.Chat.Completions
                      )
  @default_model "mistral-medium-3-5"

  def default_model do
    System.get_env("API_MODEL") ||
      System.get_env("API_CHAT_MODEL") ||
      System.get_env("MISTRAL_CHAT_MODEL") ||
      System.get_env("MISTRAL_MODEL") ||
      get_active_provider_default_model() ||
      Application.get_env(:agent, :chat_model, @default_model)
  end

  defp get_active_provider_default_model do
    provider_name = Beamcore.Config.active_provider()

    case Beamcore.Config.get_provider(provider_name) do
      %{"default_model" => model} when is_binary(model) -> model
      _ -> nil
    end
  end

  @doc """
  Execute an API call with retry logic.
  """
  def execute(client, messages, tools, context \\ :main, opts \\ []) do
    # Input validation
    if !is_list(messages) || length(messages) == 0 do
      {:error, "Messages must be a non-empty list."}
    else
      if tools && !is_list(tools) do
        {:error, "Tools must be a list."}
      else
        tools = tools || []

        model = Keyword.get(opts, :model, default_model())

        retry_config = Keyword.get(opts, :retry_config) || retry_config()

        Beamcore.Retry.execute(
          fn ->
            try do
              response = execute_provider_call(client, model, messages, tools, opts)

              case response do
                {:error, %OpenaiEx.Error{kind: :bad_request} = error} ->
                  maybe_print_debug(opts, messages, tools, model, error)
                  format_response(response, context, opts)

                {:error, %OpenaiEx.Error{status_code: 400} = error} ->
                  maybe_print_debug(opts, messages, tools, model, error)
                  format_response(response, context, opts)

                {:error, error} ->
                  if is_binary(error) &&
                       (String.contains?(error, "bad_request") ||
                          String.contains?(error, "status_code: 400")) do
                    maybe_print_debug(opts, messages, tools, model, error)
                    format_response(response, context, opts)
                  else
                    format_response(response, context, opts)
                  end

                response ->
                  format_response(response, context, opts)
              end
            rescue
              e ->
                {:error, e}
            end
          end,
          retry_config
        )
      end
    end
  end

  defp execute_provider_call(client, model, messages, tools, opts) do
    case Keyword.get(opts, :selection) do
      %{provider: _provider} = selection ->
        request = %{
          model: model,
          messages: messages,
          tools: tools
        }

        request =
          [:temperature, :top_p, :max_tokens]
          |> Enum.reduce(request, fn key, acc ->
            case Keyword.get(opts, key) do
              nil -> acc
              val -> Map.put(acc, key, val)
            end
          end)

        Beamcore.Provider.Router.chat(selection, request)

      _ ->
        Beamcore.RateLimiter.wait()

        params = %{model: model, messages: messages, tools: tools}

        params =
          [:temperature, :top_p, :max_tokens]
          |> Enum.reduce(params, fn key, acc ->
            case Keyword.get(opts, key) do
              nil -> acc
              val -> Map.put(acc, key, val)
            end
          end)

        @completions_module.create(client, params)
    end
  end

  defp retry_config do
    %Config{
      max_retries: 3,
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

  defp format_response(
         {:ok,
          %{"choices" => [%{"message" => %{"tool_calls" => tool_calls} = message} | _]} =
            response_map},
         context,
         opts
       )
       when is_list(tool_calls) do
    format_response_with_context(response_map, message, tool_calls, context, opts)
  end

  defp format_response(
         {:ok, %{"choices" => [%{"message" => message} | _]} = response_map},
         _context,
         _opts
       ) do
    {:ok, %{message: message, raw_response: response_map}}
  end

  defp format_response({:ok, response_map}, context, opts) do
    # Fallback clause
    message = (response_map["choices"] |> List.first())["message"]

    if Map.has_key?(message, "tool_calls") and not Keyword.get(opts, :silent, false) do
      if content = message["content"],
        do: Beamcore.Agent.Core.Pretty.print_thinking(content, context)
    end

    {:ok, %{message: message, raw_response: response_map}}
  end

  defp format_response({:error, %OpenaiEx.Error{} = error}, _context, _opts) do
    {:error, error}
  end

  defp format_response({:error, reason}, _context, _opts) do
    {:error, reason}
  end

  defp format_response_with_context(response_map, message, _tool_calls, context, opts) do
    # Tool calls are intentionally not printed here.
    # The chat loop prints them only after runtime capabilities authorization.
    # This prevents blocked mutation attempts from looking like executed tools.
    case Map.get(message, "content") do
      content when is_binary(content) and content != "" ->
        unless Keyword.get(opts, :silent, false) do
          Beamcore.Agent.Core.Pretty.print_thinking(content, context)
        end

      _ ->
        :ok
    end

    {:ok, %{message: message, raw_response: response_map}}
  end

  defp maybe_print_debug(opts, messages, tools, model, error_info) do
    unless Keyword.get(opts, :silent, false) do
      print_debug_info(messages, tools, model, error_info)
    end
  end

  defp print_debug_info(messages, tools, model, error_info) do
    alias Beamcore.Agent.Core.Pretty
    alias Beamcore.Agent.Core.Pretty.Colors

    separator =
      Pretty.colorize(
        "===============================================================================",
        &Colors.bright_red/0
      )

    IO.puts("\n" <> separator)
    IO.puts(Pretty.colorize("🚨  API BAD REQUEST ERROR DEBUG INFO", &Colors.bright_red/0))
    IO.puts(separator)

    # 1. Extract and display the REAL error from the API
    IO.puts("\n" <> Pretty.colorize("👉  ERROR DETAILS:", &Colors.bright_yellow/0))
    print_extracted_error(error_info)

    # 2. Message diagnostics (not the full dump — that's useless noise)
    IO.puts("\n" <> Pretty.colorize("👉  REQUEST DIAGNOSTICS:", &Colors.bright_yellow/0))
    IO.puts(Pretty.colorize("  Model: ", &Colors.dim/0) <> inspect(model))
    IO.puts(Pretty.colorize("  Tool count: ", &Colors.dim/0) <> inspect(length(tools || [])))
    IO.puts(Pretty.colorize("  Message count: ", &Colors.dim/0) <> inspect(length(messages)))

    # Role sequence
    roles = Enum.map(messages, fn m -> m[:role] || m["role"] || "?" end)
    IO.puts(Pretty.colorize("  Role sequence: ", &Colors.dim/0) <> Enum.join(roles, " → "))

    # Per-message content sizes
    IO.puts(Pretty.colorize("  Message sizes (chars):", &Colors.dim/0))

    messages
    |> Enum.with_index(1)
    |> Enum.each(fn {msg, i} ->
      role = msg[:role] || msg["role"] || "?"
      content = msg[:content] || msg["content"] || ""
      content_len = if is_binary(content), do: String.length(content), else: 0
      has_tool_calls = if msg["tool_calls"], do: " [has tool_calls]", else: ""

      tool_call_id =
        if msg[:tool_call_id] || msg["tool_call_id"],
          do: " [tool_call_id: #{msg[:tool_call_id] || msg["tool_call_id"]}]",
          else: ""

      IO.puts(
        "    #{String.pad_leading(to_string(i), 3)}. #{String.pad_trailing(role, 10)} #{String.pad_leading(to_string(content_len), 8)} chars#{has_tool_calls}#{tool_call_id}"
      )
    end)

    # Estimated total tokens
    total_chars =
      messages
      |> Enum.map(fn msg ->
        content = msg[:content] || msg["content"] || ""
        if is_binary(content), do: String.length(content), else: 0
      end)
      |> Enum.sum()

    estimated_tokens = div(total_chars, 4)
    tools_json_size = tools |> inspect() |> String.length()
    estimated_tool_tokens = div(tools_json_size, 4)

    IO.puts(Pretty.colorize("\n  Total content chars: ", &Colors.dim/0) <> "#{total_chars}")

    IO.puts(
      Pretty.colorize("  Estimated content tokens: ", &Colors.dim/0) <> "~#{estimated_tokens}"
    )

    IO.puts(
      Pretty.colorize("  Estimated tool schema tokens: ", &Colors.dim/0) <>
        "~#{estimated_tool_tokens}"
    )

    IO.puts(
      Pretty.colorize("  Estimated total prompt tokens: ", &Colors.bright_yellow/0) <>
        "~#{estimated_tokens + estimated_tool_tokens}"
    )

    # 3. Sequence validation warnings
    IO.puts("\n" <> Pretty.colorize("👉  SEQUENCE VALIDATION:", &Colors.bright_yellow/0))
    validate_message_sequence(messages)

    IO.puts(separator <> "\n")
  end

  # Extract the real error message from various error formats
  defp print_extracted_error(%OpenaiEx.Error{} = error) do
    alias Beamcore.Agent.Core.Pretty
    alias Beamcore.Agent.Core.Pretty.Colors

    IO.puts(Pretty.colorize("  Kind: ", &Colors.dim/0) <> inspect(error.kind))
    IO.puts(Pretty.colorize("  Status: ", &Colors.dim/0) <> inspect(error.status_code))

    extracted_message =
      cond do
        error.status_code == 400 or error.kind == :bad_request ->
          "API Bad Request (Likely out of context size limit)"

        error.message && error.message != "" ->
          error.message

        error.body && is_map(error.body) && error.body["message"] ->
          error.body["message"]

        true ->
          "Unknown API error"
      end

    IO.puts(Pretty.colorize("  Message: ", &Colors.bright_red/0) <> extracted_message)

    if error.body do
      IO.puts(
        Pretty.colorize("  Body: ", &Colors.bright_red/0) <> inspect(error.body, pretty: true)
      )
    end
  end

  defp print_extracted_error(error) when is_binary(error) do
    alias Beamcore.Agent.Core.Pretty
    alias Beamcore.Agent.Core.Pretty.Colors

    IO.puts(Pretty.colorize("  Message: ", &Colors.bright_red/0) <> error)
  end

  # Validate message sequence and print warnings
  defp validate_message_sequence(messages) do
    alias Beamcore.Agent.Core.Pretty
    alias Beamcore.Agent.Core.Pretty.Colors

    issues = []

    roles = Enum.map(messages, fn m -> m[:role] || m["role"] || "?" end)

    # Check for orphaned tool messages (tool without preceding assistant with tool_calls)
    issues =
      messages
      |> Enum.with_index()
      |> Enum.reduce(issues, fn {msg, i}, acc ->
        role = msg[:role] || msg["role"]

        if role == "tool" and i > 0 do
          prev = Enum.at(messages, i - 1)
          prev_role = prev[:role] || prev["role"]
          prev_has_tool_calls = prev["tool_calls"] != nil

          cond do
            prev_role == "tool" ->
              # Multiple tool responses in a row is fine (for parallel tool calls)
              acc

            prev_role == "assistant" and prev_has_tool_calls ->
              acc

            true ->
              [
                "  ⚠ Message #{i + 1} (tool) is orphaned — previous message is #{prev_role} without tool_calls"
                | acc
              ]
          end
        else
          acc
        end
      end)

    # Check for consecutive user messages
    issues =
      roles
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.reduce(issues, fn {[a, b], i}, acc ->
        if a == "user" and b == "user" do
          ["  ⚠ Consecutive user messages at positions #{i + 1} and #{i + 2}" | acc]
        else
          acc
        end
      end)

    # Check first non-system message
    first_non_system = Enum.find(roles, fn r -> r != "system" end)

    issues =
      if first_non_system == "tool" do
        ["  ⚠ First non-system message is a tool response (must be user or assistant)" | issues]
      else
        issues
      end

    if issues == [] do
      IO.puts(Pretty.colorize("  ✓ Message sequence looks valid", &Colors.green/0))
    else
      issues
      |> Enum.reverse()
      |> Enum.each(fn issue ->
        IO.puts(Pretty.colorize(issue, &Colors.bright_red/0))
      end)
    end
  end

  @doc """
  Extracts reasoning content from a completions message map.
  Supports both reasoning_content fields and <think>...</think> tags inside content.
  """
  def extract_reasoning(message) do
    reasoning =
      Map.get(message, "reasoning_content") ||
        Map.get(message, "reasoning") ||
        Map.get(message, :reasoning_content) ||
        Map.get(message, :reasoning)

    content = Map.get(message, "content") || Map.get(message, :content) || ""

    {cleaned_content, reasoning} =
      if is_binary(content) and (reasoning == nil or reasoning == "") do
        case Regex.run(~r/<think>(.*?)<\/think>/s, content) do
          [full_match, think_content] ->
            cleaned = String.replace(content, full_match, "") |> String.trim()
            {cleaned, String.trim(think_content)}

          nil ->
            {content, nil}
        end
      else
        {content, reasoning}
      end

    {cleaned_content, reasoning}
  end
end
