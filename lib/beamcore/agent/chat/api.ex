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
  @default_model nil

  def default_model do
    System.get_env("API_MODEL") ||
      System.get_env("API_CHAT_MODEL") ||
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
                {:error, %OpenaiEx.Error{kind: :bad_request}} ->
                  format_response(response, context, opts)

                {:error, %OpenaiEx.Error{status_code: 400}} ->
                  format_response(response, context, opts)

                {:error, error} ->
                  if is_binary(error) &&
                       (String.contains?(error, "bad_request") ||
                          String.contains?(error, "status_code: 400")) do
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

        Beamcore.Provider.Router.chat(selection, request, opts)

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

  defp format_response({:ok, response_map}, _context, _opts) do
    # Fallback clause
    message = (response_map["choices"] |> List.first())["message"]
    {:ok, %{message: message, raw_response: response_map}}
  end

  defp format_response({:error, %OpenaiEx.Error{} = error}, _context, _opts) do
    {:error, error}
  end

  defp format_response({:error, reason}, _context, _opts) do
    {:error, reason}
  end

  defp format_response_with_context(response_map, message, _tool_calls, _context, _opts) do
    {:ok, %{message: message, raw_response: response_map}}
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
