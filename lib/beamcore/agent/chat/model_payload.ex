defmodule Beamcore.Agent.Chat.ModelPayload do
  @moduledoc """
  Builds bounded model-facing chat payloads.

  This does not mutate the session log or restrict tool execution. It only
  replaces oversized historical message fields before provider calls so large
  file edits and diagnostics do not exhaust the model context.
  """

  alias Beamcore.Agent.Chat.Budget

  @fallback_context_window 32_000
  @budget_ratio 0.70
  @recent_messages 6
  @max_message_content_chars 32_000
  @max_tool_content_chars 20_000
  @max_tool_result_field_chars 8_000
  @max_tool_argument_chars 16_000
  @compact_content_chars 1_200
  @compact_argument_chars 800

  def limit(messages, metadata \\ %{}) when is_list(messages) do
    token_budget = token_budget(metadata)

    messages
    |> Enum.map(&limit_message/1)
    |> enforce_total_budget(token_budget)
  end

  defp limit_message(message) do
    role = message[:role] || message["role"]

    message
    |> limit_content(role)
    |> limit_tool_calls(role)
  end

  defp limit_content(message, "tool") do
    update_content(message, &limit_tool_content/1)
  end

  defp limit_content(message, _role) do
    update_content(message, &bounded_text(&1, @max_message_content_chars, "message content"))
  end

  defp update_content(message, fun) do
    cond do
      is_binary(Map.get(message, :content)) ->
        Map.update!(message, :content, fun)

      is_binary(Map.get(message, "content")) ->
        Map.update!(message, "content", fun)

      true ->
        message
    end
  end

  defp limit_tool_calls(message, "assistant") do
    cond do
      is_list(Map.get(message, :tool_calls)) ->
        Map.update!(message, :tool_calls, &Enum.map(&1, fn call -> limit_tool_call(call) end))

      is_list(Map.get(message, "tool_calls")) ->
        Map.update!(message, "tool_calls", &Enum.map(&1, fn call -> limit_tool_call(call) end))

      true ->
        message
    end
  end

  defp limit_tool_calls(message, _role), do: message

  defp limit_tool_call(call) when is_map(call) do
    function = Map.get(call, :function) || Map.get(call, "function")

    if is_map(function) do
      updated = limit_function_arguments(function, @max_tool_argument_chars)
      put_function(call, updated)
    else
      call
    end
  end

  defp limit_tool_call(call), do: call

  defp put_function(call, function) do
    cond do
      Map.has_key?(call, :function) -> Map.put(call, :function, function)
      Map.has_key?(call, "function") -> Map.put(call, "function", function)
      true -> call
    end
  end

  defp limit_function_arguments(function, max_chars) do
    cond do
      is_binary(Map.get(function, :arguments)) ->
        Map.update!(function, :arguments, &limit_arguments(&1, max_chars))

      is_binary(Map.get(function, "arguments")) ->
        Map.update!(function, "arguments", &limit_arguments(&1, max_chars))

      true ->
        function
    end
  end

  defp limit_arguments(arguments, max_chars) do
    if String.length(arguments) <= max_chars do
      arguments
    else
      case Jason.decode(arguments) do
        {:ok, decoded} when is_map(decoded) ->
          decoded
          |> limit_json_value(max_chars, "tool arguments")
          |> Map.put("_beamcore_model_payload_limited", true)
          |> Jason.encode!()

        _ ->
          bounded_text(arguments, max_chars, "tool arguments")
      end
    end
  end

  defp limit_json_value(value, max_chars, label) when is_map(value) do
    value
    |> Enum.map(fn {key, val} ->
      {key, limit_json_value(val, max_chars, label_for(key, label))}
    end)
    |> Map.new()
  end

  defp limit_json_value(value, max_chars, label) when is_list(value) do
    Enum.map(value, &limit_json_value(&1, max_chars, label))
  end

  defp limit_json_value(value, max_chars, label) when is_binary(value) do
    bounded_text(value, max_chars, label)
  end

  defp limit_json_value(value, _max_chars, _label), do: value

  defp label_for(key, fallback), do: to_string(key || fallback)

  defp limit_tool_content(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> limit_tool_result_map()
        |> Map.put("_beamcore_model_payload_limited", true)
        |> Jason.encode!()

      _ ->
        bounded_text(content, @max_tool_content_chars, "tool output")
    end
  end

  defp limit_tool_result_map(result) do
    result
    |> limit_field("stdout")
    |> limit_field("stderr")
    |> limit_field("result")
  end

  defp limit_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        Map.put(map, key, bounded_text(value, @max_tool_result_field_chars, key))

      _ ->
        map
    end
  end

  defp enforce_total_budget(messages, token_budget) do
    target = trunc(token_budget * @budget_ratio)

    if Budget.estimate_tokens(messages) <= target do
      messages
    else
      compact_older_messages(messages)
    end
  end

  defp compact_older_messages(messages) do
    {system, rest} = Enum.split_with(messages, &(role(&1) == "system"))
    keep_count = min(length(rest), @recent_messages)
    {older, recent} = Enum.split(rest, length(rest) - keep_count)

    system ++ Enum.map(older, &compact_message/1) ++ recent
  end

  defp compact_message(message) do
    role = role(message)

    message
    |> compact_content(role)
    |> compact_tool_calls(role)
  end

  defp compact_content(message, "tool") do
    update_content(message, fn content ->
      bounded_text(content, @compact_content_chars, "older tool output")
    end)
  end

  defp compact_content(message, _role) do
    update_content(message, fn content ->
      bounded_text(content, @compact_content_chars, "older message content")
    end)
  end

  defp compact_tool_calls(message, "assistant") do
    cond do
      is_list(Map.get(message, :tool_calls)) ->
        Map.update!(message, :tool_calls, &Enum.map(&1, fn call -> compact_tool_call(call) end))

      is_list(Map.get(message, "tool_calls")) ->
        Map.update!(message, "tool_calls", &Enum.map(&1, fn call -> compact_tool_call(call) end))

      true ->
        message
    end
  end

  defp compact_tool_calls(message, _role), do: message

  defp compact_tool_call(call) when is_map(call) do
    function = Map.get(call, :function) || Map.get(call, "function")

    if is_map(function) do
      put_function(call, limit_function_arguments(function, @compact_argument_chars))
    else
      call
    end
  end

  defp compact_tool_call(call), do: call

  defp bounded_text(text, max_chars, label) when is_binary(text) do
    if String.length(text) <= max_chars do
      text
    else
      head_chars = max(div(max_chars * 2, 3), 0)
      tail_chars = max(max_chars - head_chars, 0)
      omitted = String.length(text) - max_chars

      String.slice(text, 0, head_chars) <>
        "\n...[#{label} truncated for model context: #{omitted} character(s) omitted]...\n" <>
        String.slice(text, max(String.length(text) - tail_chars, 0), tail_chars)
    end
  end

  defp bounded_text(value, _max_chars, _label), do: value

  defp token_budget(metadata) do
    context_window =
      cond do
        is_map(metadata) ->
          Map.get(metadata, :context_window) || Map.get(metadata, "context_window")

        true ->
          nil
      end

    if is_integer(context_window) and context_window > 0 do
      context_window
    else
      @fallback_context_window
    end
  end

  defp role(message), do: message[:role] || message["role"]
end
