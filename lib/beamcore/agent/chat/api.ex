defmodule Beamcore.Agent.Chat.API do
  @moduledoc """
  Handles API calls to the OpenAI-compatible endpoint.
  """
  alias Beamcore.Retry.Config

  @completions_module Application.compile_env(
                        :beamcore,
                        :completions_module,
                        OpenaiEx.Chat.Completions
                      )

  def default_model do
    get_active_provider_default_model() ||
      Application.get_env(:beamcore, :chat_model)
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
  def execute(client, messages, tools, opts \\ []) do
    cond do
      !is_list(messages) || length(messages) == 0 ->
        {:error, "Messages must be a non-empty list."}

      tools && !is_list(tools) ->
        {:error, "Tools must be a list."}

      true ->
        tools = tools || []
        model = Keyword.get(opts, :model, default_model())
        retry_config = Keyword.get(opts, :retry_config) || retry_config()

        Beamcore.Retry.execute(
          fn ->
            try do
              request = build_request(model, messages, tools, opts)

              case Keyword.get(opts, :selection) do
                %{provider: _} = selection ->
                  Beamcore.Provider.Router.chat(selection, request, opts)

                _ ->
                  @completions_module.create(client, request)
              end
              |> format_response(opts)
            rescue
              e -> {:error, e}
            end
          end,
          retry_config
        )
    end
  end

  defp build_request(model, messages, tools, opts) do
    base = %{model: model, messages: messages, tools: tools}

    [:temperature, :top_p, :max_tokens]
    |> Enum.reduce(base, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        val -> Map.put(acc, key, val)
      end
    end)
  end

  defp retry_config do
    Config.default()
  end

  defp format_response(
         {:ok,
          %{"choices" => [%{"message" => %{"tool_calls" => _} = message} | _]} = response_map},
         _opts
       ) do
    {:ok, %{message: message, raw_response: response_map}}
  end

  defp format_response(
         {:ok, %{"choices" => [%{"message" => message} | _]} = response_map},
         _opts
       ) do
    {:ok, %{message: message, raw_response: response_map}}
  end

  defp format_response({:ok, response_map}, _opts) do
    case response_map do
      %{"choices" => [%{"message" => message} | _]} ->
        {:ok, %{message: message, raw_response: response_map}}

      %{"choices" => []} ->
        Beamcore.AppLog.warn("API returned empty choices", response: response_map)

        {:error,
         "API returned empty response. Full response: #{inspect(response_map, limit: 500)}"}

      %{"error" => %{"message" => msg}} ->
        {:error, msg}

      %{"error" => msg} when is_binary(msg) ->
        {:error, msg}

      _ ->
        Beamcore.AppLog.warn("Unexpected API response format", response: response_map)
        {:error, "Unexpected API response: #{inspect(response_map, limit: 500)}"}
    end
  end

  defp format_response({:error, %OpenaiEx.Error{} = error}, _opts) do
    {:error, error}
  end

  defp format_response({:error, reason}, _opts) do
    {:error, reason}
  end

  @doc """
  Execute a streaming API call. Returns {:ok, ref} on success.
  Chunks arrive as messages to the receiver pid:
    {:stream_chunk, chunk_map}
    {:stream_done, task_pid}
    {:stream_error, reason, task_pid}
  """
  def execute_stream(client, messages, tools, opts \\ []) do
    cond do
      !is_list(messages) || length(messages) == 0 ->
        {:error, "Messages must be a non-empty list."}

      tools && !is_list(tools) ->
        {:error, "Tools must be a list."}

      true ->
        tools = tools || []
        model = Keyword.get(opts, :model, default_model())
        receiver = Keyword.get(opts, :receiver) || self()

        request = build_request(model, messages, tools, opts)

        case Keyword.get(opts, :selection) do
          %{provider: _} = selection ->
            Beamcore.Provider.Router.stream(
              selection,
              request,
              Keyword.put(opts, :receiver, receiver)
            )

          _ ->
            # Fallback: use non-streaming for direct client path
            execute(client, messages, tools, opts)
        end
    end
  end

  @doc """
  Extracts reasoning content from a completions message map.
  Supports both reasoning_content fields and ...</think> tags inside content.
  """
  def extract_reasoning(nil), do: {"", nil}
  def extract_reasoning(message) when not is_map(message), do: {"", nil}

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
