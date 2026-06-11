defmodule Beamcore.Agent.Chat.Budget do
  @moduledoc """
  Approximate message budgeting for provider calls.

  This deliberately uses a deterministic character-based estimate. It is not a
  tokenizer, but it is good enough to prevent unbounded history, tool output, or
  research notes from flooding local models.
  """

  @chars_per_token 4
  @min_message_chars 400

  @doc """
  Estimate tokens from message content and tool-call arguments.
  """
  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&message_chars/1)
    |> Enum.sum()
    |> div(@chars_per_token)
  end

  @doc """
  Reduce messages until they fit the approximate token budget.

  System messages and the newest user message are preferred. Older messages are
  kept from newest to oldest, with long content compacted if needed.
  """
  def fit_messages(messages, budget)
      when is_list(messages) and is_integer(budget) and budget > 0 do
    max_chars = budget * @chars_per_token

    {system_messages, other_messages} =
      Enum.split_with(messages, fn message ->
        role(message) == "system"
      end)

    latest_user = latest_user_message(other_messages)
    reserved = Enum.uniq(system_messages ++ List.wrap(latest_user))
    remaining_budget = max(max_chars - total_chars(reserved), @min_message_chars)

    kept =
      other_messages
      |> Enum.reject(&(&1 == latest_user))
      |> Enum.reverse()
      |> keep_within_chars(remaining_budget, [])
      |> Enum.reverse()

    result = reserved ++ kept

    if total_chars(result) <= max_chars do
      result
    else
      compact_messages(result, max_chars)
    end
  end

  def fit_messages(messages, _budget), do: messages

  def compact_text(text, max_chars) when is_binary(text) and is_integer(max_chars) do
    cond do
      max_chars <= 0 ->
        ""

      String.length(text) <= max_chars ->
        text

      max_chars < 80 ->
        String.slice(text, 0, max_chars)

      true ->
        head_size = div(max_chars, 2) - 24
        tail_size = max_chars - head_size - 48
        omitted = String.length(text) - head_size - tail_size

        String.slice(text, 0, head_size) <>
          "\n[omitted #{omitted} chars]\n" <>
          String.slice(text, String.length(text) - tail_size, tail_size)
    end
  end

  def compact_text(value, max_chars), do: value |> inspect() |> compact_text(max_chars)

  defp keep_within_chars([], _remaining, acc), do: acc

  defp keep_within_chars([message | rest], remaining, acc) do
    size = message_chars(message)

    cond do
      remaining <= 0 ->
        acc

      size <= remaining ->
        keep_within_chars(rest, remaining - size, [message | acc])

      true ->
        compacted = compact_message(message, remaining)
        keep_within_chars(rest, 0, [compacted | acc])
    end
  end

  defp compact_messages(messages, max_chars) do
    per_message = max(div(max_chars, max(length(messages), 1)), @min_message_chars)

    Enum.map(messages, fn message ->
      compact_message(message, per_message)
    end)
  end

  defp compact_message(message, max_chars) do
    content = content(message)

    if is_binary(content) do
      put_content(message, compact_text(content, max_chars))
    else
      message
    end
  end

  defp total_chars(messages), do: Enum.map(messages, &message_chars/1) |> Enum.sum()

  defp message_chars(message) do
    content_size =
      case content(message) do
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

  defp latest_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn message -> role(message) == "user" end)
  end

  defp role(message), do: to_string(message[:role] || message["role"] || "")
  defp content(message), do: message[:content] || message["content"]

  defp put_content(message, value) do
    if Map.has_key?(message, :content),
      do: Map.put(message, :content, value),
      else: Map.put(message, "content", value)
  end
end
