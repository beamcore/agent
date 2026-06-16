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
    {system_messages, cleaned} = split_system(messages)
    system_messages ++ cleaned
  end

  @doc """
  Cleans and truncates a message list to the given message count limit.
  """
  def trim_and_clean(messages, limit) do
    {system_messages, cleaned} = split_system(messages)

    trimmed =
      if length(cleaned) > limit do
        Enum.take(cleaned, -limit)
      else
        cleaned
      end

    system_messages ++ trimmed
  end

  defp split_system(messages) do
    {system_messages, other_messages} =
      Enum.split_with(messages, fn m ->
        (m[:role] || m["role"]) == "system"
      end)

    cleaned =
      other_messages
      |> normalize_all_tool_calls()
      |> clean_orphaned_tools()
      |> clean_dangling_tool_calls()
      |> remove_empty_assistant_messages()
      |> ensure_starts_with_user()
      |> merge_consecutive_roles()

    cleaned =
      case cleaned do
        [] -> [%{role: "user", content: "Continuing the conversation."}]
        other -> other
      end

    {system_messages, cleaned}
  end

  defp normalize_all_tool_calls(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      tool_calls = msg["tool_calls"] || msg[:tool_calls]

      if role == "assistant" and is_list(tool_calls) and tool_calls != [] do
        fixed =
          Enum.map(tool_calls, fn tc ->
            tc
            |> Map.put("type", "function")
            |> Map.delete("index")
          end)

        if Map.has_key?(msg, :tool_calls),
          do: Map.put(msg, :tool_calls, fixed),
          else: Map.put(msg, "tool_calls", fixed)
      else
        msg
      end
    end)
  end

  defp clean_dangling_tool_calls(messages) do
    answered_ids =
      messages
      |> Enum.filter(fn msg -> (msg[:role] || msg["role"]) == "tool" end)
      |> Enum.map(fn msg -> msg[:tool_call_id] || msg["tool_call_id"] end)
      |> MapSet.new()

    {result, _answered} =
      Enum.reduce(messages, {[], answered_ids}, fn msg, {acc, ids} ->
        role = msg[:role] || msg["role"]
        tool_calls = msg["tool_calls"] || msg[:tool_calls]

        if role == "assistant" and is_list(tool_calls) and tool_calls != [] do
          {dangling, kept} =
            Enum.split_with(tool_calls, fn tc ->
              not MapSet.member?(ids, tc["id"] || tc[:id])
            end)

          if dangling == [] do
            {[msg | acc], ids}
          else
            synthetic_responses =
              Enum.map(dangling, fn tc ->
                %{
                  role: "tool",
                  tool_call_id: tc["id"] || tc[:id],
                  name: get_in(tc, ["function", "name"]) || get_in(tc, [:function, :name]),
                  content: "[Interrupted: tool execution was cancelled before completion]"
                }
              end)

            updated_msg =
              if kept == [] do
                msg |> Map.delete("tool_calls") |> Map.delete(:tool_calls)
              else
                if Map.has_key?(msg, :tool_calls),
                  do: Map.put(msg, :tool_calls, kept),
                  else: Map.put(msg, "tool_calls", kept)
              end

            new_ids =
              Enum.reduce(dangling, ids, fn tc, s ->
                MapSet.put(s, tc["id"] || tc[:id])
              end)

            {Enum.reverse(synthetic_responses) ++ [updated_msg | acc], new_ids}
          end
        else
          {[msg | acc], ids}
        end
      end)

    Enum.reverse(result)
  end

  defp remove_empty_assistant_messages(messages) do
    Enum.reject(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]
      tool_calls = msg[:tool_calls] || msg["tool_calls"]

      reasoning =
        msg[:reasoning] || msg["reasoning"] || msg[:reasoning_content] || msg["reasoning_content"]

      role == "assistant" and
        (is_nil(content) or content == "" or (is_binary(content) and String.trim(content) == "")) and
        (is_nil(tool_calls) or tool_calls == []) and
        (is_nil(reasoning) or reasoning == "" or
           (is_binary(reasoning) and String.trim(reasoning) == ""))
    end)
  end

  defp clean_orphaned_tools(messages) do
    messages =
      Enum.drop_while(messages, fn msg ->
        (msg[:role] || msg["role"]) == "tool"
      end)

    clean_orphaned_tools_helper(messages, [])
  end

  defp clean_orphaned_tools_helper([], acc), do: Enum.reverse(acc)

  defp clean_orphaned_tools_helper([msg | rest], acc) do
    role = msg[:role] || msg["role"]

    if role == "tool" do
      prev = List.first(acc)
      prev_role = if prev, do: prev[:role] || prev["role"]

      if prev_role == "assistant" or prev_role == "tool" do
        clean_orphaned_tools_helper(rest, [msg | acc])
      else
        clean_orphaned_tools_helper(rest, acc)
      end
    else
      clean_orphaned_tools_helper(rest, [msg | acc])
    end
  end

  defp ensure_starts_with_user(messages) do
    case messages do
      [] ->
        []

      [msg | _] = list ->
        if (msg[:role] || msg["role"]) == "user" do
          list
        else
          [%{role: "user", content: "Continuing the conversation."} | list]
        end
    end
  end

  defp merge_consecutive_roles(messages) do
    Enum.reduce(messages, [], fn msg, acc ->
      case acc do
        [] ->
          [msg]

        [prev | rest] ->
          prev_role = prev[:role] || prev["role"]
          curr_role = msg[:role] || msg["role"]

          if prev_role == curr_role and prev_role in ["user", "assistant"] do
            prev_content = prev[:content] || prev["content"] || ""
            curr_content = msg[:content] || msg["content"] || ""
            merged_content = prev_content <> "\n\n" <> curr_content

            prev_tool_calls = prev[:tool_calls] || prev["tool_calls"]
            curr_tool_calls = msg[:tool_calls] || msg["tool_calls"]

            merged_msg =
              if Map.has_key?(prev, :content) do
                Map.put(prev, :content, merged_content)
              else
                Map.put(prev, "content", merged_content)
              end

            merged_msg =
              cond do
                is_nil(curr_tool_calls) or curr_tool_calls == [] ->
                  merged_msg

                is_nil(prev_tool_calls) or prev_tool_calls == [] ->
                  if Map.has_key?(merged_msg, :tool_calls) do
                    Map.put(merged_msg, :tool_calls, curr_tool_calls)
                  else
                    Map.put(merged_msg, "tool_calls", curr_tool_calls)
                  end

                true ->
                  combined = prev_tool_calls ++ curr_tool_calls

                  if Map.has_key?(merged_msg, :tool_calls) do
                    Map.put(merged_msg, :tool_calls, combined)
                  else
                    Map.put(merged_msg, "tool_calls", combined)
                  end
              end

            [merged_msg | rest]
          else
            [msg | acc]
          end
      end
    end)
    |> Enum.reverse()
  end
end
