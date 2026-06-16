defmodule Beamcore.Agent.Chat.Session.MessageCleaner do
  @moduledoc """
  Cleans and normalizes message lists before they are sent to the API or summarizer.

  Handles orphaned tool responses, dangling tool calls, empty assistant messages,
  consecutive role merging, and message alternation enforcement.
  """

  @doc """
  Cleans a message list without truncating. Fixes orphaned tool responses,
  dangling tool calls, empty assistant messages, and enforces role alternation.
  """
  def clean(messages) do
    {system, rest} = split_system(messages)
    system ++ do_clean(rest)
  end

  @doc """
  Cleans and truncates a message list to the given message count limit.
  """
  def trim_and_clean(messages, limit) do
    {system, rest} = split_system(messages)
    trimmed = if length(rest) > limit, do: Enum.take(rest, -limit), else: rest
    system ++ do_clean(trimmed)
  end

  defp split_system(messages) do
    Enum.split_with(messages, &(role(&1) == "system"))
  end

  defp do_clean(messages) do
    messages
    |> normalize_tool_calls()
    |> drop_leading_orphans()
    |> fill_dangling_tool_calls()
    |> drop_orphaned_tools()
    |> drop_empty_assistant()
    |> ensure_user_first()
    |> merge_consecutive()
    |> ensure_nonempty()
  end

  # --- Field access ---

  defp role(msg), do: msg[:role] || msg["role"]
  defp content(msg), do: msg[:content] || msg["content"]
  defp tool_calls(msg), do: msg[:tool_calls] || msg["tool_calls"]
  defp tool_call_id(msg), do: msg[:tool_call_id] || msg["tool_call_id"]

  defp put_field(msg, :tool_calls, value) do
    if Map.has_key?(msg, :tool_calls),
      do: Map.put(msg, :tool_calls, value),
      else: Map.put(msg, "tool_calls", value)
  end

  defp put_field(msg, :content, value) do
    if Map.has_key?(msg, :content),
      do: Map.put(msg, :content, value),
      else: Map.put(msg, "content", value)
  end

  defp delete_field(msg, :tool_calls) do
    msg |> Map.delete(:tool_calls) |> Map.delete("tool_calls")
  end

  # --- Pipeline ---

  defp normalize_tool_calls(messages) do
    Enum.map(messages, fn msg ->
      tc = tool_calls(msg)

      if role(msg) == "assistant" and is_list(tc) and tc != [] do
        fixed = Enum.map(tc, fn t -> t |> Map.put("type", "function") |> Map.delete("index") end)
        put_field(msg, :tool_calls, fixed)
      else
        msg
      end
    end)
  end

  defp drop_leading_orphans(messages) do
    Enum.drop_while(messages, &(role(&1) == "tool"))
  end

  defp fill_dangling_tool_calls(messages) do
    answered =
      messages
      |> Enum.filter(&(role(&1) == "tool"))
      |> Enum.map(&tool_call_id/1)
      |> MapSet.new()

    {result, _} =
      Enum.reduce(messages, {[], answered}, fn msg, {acc, ids} ->
        tc = tool_calls(msg)

        if role(msg) == "assistant" and is_list(tc) and tc != [] do
          {dangling, kept} =
            Enum.split_with(tc, fn t -> not MapSet.member?(ids, t["id"] || t[:id]) end)

          if dangling == [] do
            {[msg | acc], ids}
          else
            synthetic =
              Enum.map(dangling, fn t ->
                %{
                  role: "tool",
                  tool_call_id: t["id"] || t[:id],
                  name: get_in(t, [:function, :name]) || get_in(t, ["function", "name"]),
                  content: "[Interrupted: tool execution was cancelled before completion]"
                }
              end)

            updated =
              if kept == [] do
                delete_field(msg, :tool_calls)
              else
                put_field(msg, :tool_calls, kept)
              end

            new_ids =
              Enum.reduce(dangling, ids, fn t, s -> MapSet.put(s, t["id"] || t[:id]) end)

            {Enum.reverse(synthetic) ++ [updated | acc], new_ids}
          end
        else
          {[msg | acc], ids}
        end
      end)

    Enum.reverse(result)
  end

  defp drop_orphaned_tools(messages) do
    Enum.reduce(messages, [], fn msg, acc ->
      if role(msg) == "tool" do
        prev = List.first(acc)
        if prev && role(prev) in ["assistant", "tool"], do: [msg | acc], else: acc
      else
        [msg | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp drop_empty_assistant(messages) do
    Enum.reject(messages, fn msg ->
      role(msg) == "assistant" and
        blank?(content(msg)) and
        (is_nil(tool_calls(msg)) or tool_calls(msg) == []) and
        blank?(
          msg[:reasoning] || msg["reasoning"] || msg[:reasoning_content] ||
            msg["reasoning_content"]
        )
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp ensure_user_first([]), do: []

  defp ensure_user_first([msg | _] = msgs) do
    if role(msg) == "user",
      do: msgs,
      else: [%{role: "user", content: "Continuing the conversation."} | msgs]
  end

  defp merge_consecutive(messages) do
    Enum.reduce(messages, [], fn msg, acc ->
      case acc do
        [] ->
          [msg]

        [prev | rest] ->
          if role(prev) == role(msg) and role(prev) in ["user", "assistant"] do
            [merge_two(prev, msg) | rest]
          else
            [msg | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp merge_two(prev, msg) do
    merged = put_field(prev, :content, (content(prev) || "") <> "\n\n" <> (content(msg) || ""))

    case {tool_calls(prev), tool_calls(msg)} do
      {_, nil} -> merged
      {_, []} -> merged
      {nil, tc} -> put_field(merged, :tool_calls, tc)
      {[], tc} -> put_field(merged, :tool_calls, tc)
      {tc1, tc2} -> put_field(merged, :tool_calls, tc1 ++ tc2)
    end
  end

  defp ensure_nonempty([]), do: [%{role: "user", content: "Continuing the conversation."}]
  defp ensure_nonempty(msgs), do: msgs
end
