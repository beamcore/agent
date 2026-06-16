defmodule Beamcore.Agent.Chat.Budget do
  @moduledoc """
  Token estimation for provider calls.

  Uses a deterministic character-based estimate (not a tokenizer) for
  reporting and telemetry. No messages are ever dropped or truncated.
  """

  @chars_per_token 4

  @doc """
  Estimate tokens from a list of messages.
  """
  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&message_chars/1)
    |> Enum.sum()
    |> div(@chars_per_token)
  end

  defp message_chars(message) do
    content_size =
      case message[:content] || message["content"] do
        value when is_binary(value) -> String.length(value)
        nil -> 0
        value -> inspect(value) |> String.length()
      end

    tool_size =
      case message[:tool_calls] || message["tool_calls"] do
        nil -> 0
        value -> inspect(value) |> String.length()
      end

    content_size + tool_size
  end
end
