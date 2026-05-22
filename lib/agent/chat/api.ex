defmodule Beamcore.Agent.Chat.API do
  @moduledoc """
  Handles API calls to the OpenAI-compatible endpoint.
  """

  alias Beamcore.Agent.Retry.Config

  @completions_module Application.compile_env(
                        :agent,
                        :completions_module,
                        OpenaiEx.Chat.Completions
                      )
  @default_model "mistral-medium-3.5"

  @doc """
  Execute an API call with retry logic.
  """
  def execute(client, messages, tools, context \\ :main) do
    # Input validation
    if !is_list(messages) || length(messages) == 0 do
      {:error, "Messages must be a non-empty list."}
    else
      if tools && !is_list(tools) do
        {:error, "Tools must be a list."}
      else
        tools = tools || []

        # Custom retry config for bad_request errors: 3 retries, 5s delay
        retry_config = %Config{
          max_retries: 3,
          initial_backoff: 5000,
          max_backoff: 5000,
          backoff_multiplier: 1,
          retryable_errors: [
            :bad_request,
            :rate_limit,
            :api_timeout_error,
            :api_connection_error,
            :internal_server_error
          ]
        }

        Beamcore.Agent.Chat.RateLimiter.wait()

        Beamcore.Agent.Retry.execute(
          fn ->
            try do
              response =
                @completions_module.create(
                  client,
                  %{
                    model: @default_model,
                    messages: messages,
                    tools: tools
                  }
                )

              case response do
                {:error, %OpenaiEx.Error{kind: :bad_request} = error} ->
                  print_debug_info(messages, tools, @default_model, error)
                  format_response(response, context)

                {:error, %OpenaiEx.Error{status_code: 400} = error} ->
                  print_debug_info(messages, tools, @default_model, error)
                  format_response(response, context)

                {:error, reason} when is_binary(reason) ->
                  if String.contains?(reason, "status_code: 400") do
                    print_debug_info(messages, tools, @default_model, reason)
                  end

                  format_response(response, context)

                _ ->
                  format_response(response, context)
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

  defp format_response(
         {:ok,
          %{"choices" => [%{"message" => %{"tool_calls" => tool_calls} = message} | _]} =
            response_map},
         context
       )
       when is_list(tool_calls) do
    format_response_with_context(response_map, message, tool_calls, context)
  end

  defp format_response(
         {:ok, %{"choices" => [%{"message" => message} | _]} = response_map},
         _context
       ) do
    {:ok, %{message: message, raw_response: response_map}}
  end

  defp format_response({:ok, response_map}, context) do
    # Fallback clause
    message = (response_map["choices"] |> List.first())["message"]

    if Map.has_key?(message, "tool_calls") do
      if content = message["content"],
        do: Beamcore.Agent.Core.Pretty.print_thinking(content, context)
    end

    {:ok, %{message: message, raw_response: response_map}}
  end

  defp format_response({:error, %OpenaiEx.Error{} = error}, _context) do
    {:error, error}
  end

  defp format_response({:error, reason}, _context) do
    {:error, reason}
  end

  defp format_response(response, _context) do
    {:error, "Unexpected response format: #{inspect(response)}"}
  end

  defp format_response_with_context(response_map, message, tool_calls, context) do
    # Print thinking content if present
    case Map.get(message, "content") do
      content when is_binary(content) and content != "" ->
        Beamcore.Agent.Core.Pretty.print_thinking(content, context)

      _ ->
        :ok
    end

    # Print tool calls
    Enum.each(tool_calls, fn tool ->
      name = get_in(tool, ["function", "name"])
      raw_args = get_in(tool, ["function", "arguments"])

      parsed_args =
        case Jason.decode(raw_args) do
          {:ok, decoded} -> decoded
          _ -> raw_args
        end

      Beamcore.Agent.Core.Pretty.print_tool_call(name, parsed_args, context)
    end)

    {:ok, %{message: message, raw_response: response_map}}
  end

  defp print_debug_info(messages, tools, model, error_info) do
    alias Beamcore.Agent.Core.Pretty
    alias Beamcore.Agent.Core.Pretty.Colors

    IO.puts(
      "\n" <>
        Pretty.colorize(
          "===============================================================================",
          &Colors.bright_red/0
        )
    )

    IO.puts(Pretty.colorize("🚨  API BAD REQUEST ERROR DEBUG INFO", &Colors.bright_red/0))

    IO.puts(
      Pretty.colorize(
        "===============================================================================",
        &Colors.bright_red/0
      )
    )

    # 1. What we received back
    IO.puts("\n" <> Pretty.colorize("👉  WHAT WE RECEIVED BACK:", &Colors.bright_yellow/0))
    IO.puts(inspect(error_info, pretty: true))

    # 2. What we've sent
    IO.puts("\n" <> Pretty.colorize("👉  WHAT WE'VE SENT:", &Colors.bright_yellow/0))
    IO.puts(Pretty.colorize("Model: ", &Colors.dim/0) <> inspect(model))
    IO.puts(Pretty.colorize("Tools: ", &Colors.dim/0) <> inspect(tools, pretty: true))
    IO.puts(Pretty.colorize("Messages: ", &Colors.dim/0) <> inspect(messages, pretty: true))

    # 3. Entire stack
    IO.puts("\n" <> Pretty.colorize("👉  ENTIRE STACKTRACE:", &Colors.bright_yellow/0))

    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
    IO.puts(Exception.format_stacktrace(stacktrace))

    IO.puts(
      Pretty.colorize(
        "===============================================================================",
        &Colors.bright_red/0
      ) <> "\n"
    )
  end
end
