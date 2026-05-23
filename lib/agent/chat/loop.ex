defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{API, Commands, Context, MultilineInput, Session, ToolPolicy}
  alias Beamcore.Agent.Core.{Pretty, StatusBar}
  alias Beamcore.Agent.Tools.Dispatcher

  @max_tool_depth 12

  @doc """
  Start the chat loop with the given session and status bar PID.
  """
  def start(session, pid) do
    loop(session, pid)
  end

  defp loop(session, pid) do
    StatusBar.update(pid, session)
    Pretty.print_prompt()

    case IO.gets("") do
      :eof ->
        StatusBar.reset(pid)
        IO.puts("\nGoodbye!")

      input when is_binary(input) ->
        case String.trim(input) do
          "" ->
            loop(session, pid)

          "/" <> command ->
            handle_command(command, session, pid)

          "<<<" ->
            handle_paste(session, pid, ">>>")

          trimmed ->
            new_session = send_message(session, trimmed, pid)
            loop(new_session, pid)
        end

      _ ->
        :ok
    end
  end

  defp handle_command("paste", session, pid), do: handle_paste(session, pid, "/end")

  defp handle_command(command, session, pid) do
    case Commands.execute(command, session) do
      {:run_pending, confirmed_session, content, policy} ->
        confirmed_session
        |> send_message(content, pid, policy)
        |> Session.clear_pending_action()
        |> loop(pid)

      new_session ->
        loop(new_session, pid)
    end
  end

  defp handle_paste(session, pid, terminator) do
    IO.puts("Paste multi-line input. Finish with #{terminator}.")

    case collect_paste([], terminator) do
      {:ok, text} ->
        session
        |> send_message(text, pid)
        |> loop(pid)

      {:error, :empty} ->
        Beamcore.Agent.Core.Pretty.print_error("Empty paste ignored.")
        loop(session, pid)
    end
  end

  defp collect_paste(lines, terminator) do
    case IO.gets("") do
      :eof ->
        lines
        |> MultilineInput.collect_until(terminator)
        |> eof_paste_result()

      input when is_binary(input) ->
        line = String.trim_trailing(input, "\n") |> String.trim_trailing("\r")

        case MultilineInput.collect_until(lines ++ [line], terminator) do
          {:ok, text, _rest} -> {:ok, text}
          {:error, :empty, _rest} -> {:error, :empty}
          {:more, _text} -> collect_paste(lines ++ [line], terminator)
        end
    end
  end

  defp eof_paste_result({:ok, text, _rest}), do: {:ok, text}
  defp eof_paste_result({:error, :empty, _rest}), do: {:error, :empty}

  defp eof_paste_result({:more, text}) do
    if String.trim(text) == "", do: {:error, :empty}, else: {:ok, String.trim(text)}
  end

  defp send_message(session, content, pid, policy_override \\ nil) do
    policy = policy_override || ToolPolicy.from_user_message(content)

    session =
      if ToolPolicy.confirmation_required?(policy) do
        %{session | pending_user_message: content}
      else
        %{session | pending_user_message: nil}
      end

    session = %{session | context: Context.from_user_request(session.context, content, policy)}
    user_message = %{role: "user", content: content}
    Session.log(session, user_message)

    messages = session.messages ++ [user_message]
    process_messages(session, messages, pid, 0, policy)
  end

  defp process_messages(session, messages, _pid, depth, _policy) when depth >= @max_tool_depth do
    Pretty.print_warning("Tool loop depth limit (#{@max_tool_depth}) reached. Stopping.")
    %{session | messages: Session.compact_history(messages)}
  end

  defp process_messages(session, messages, pid, depth, policy) do
    tools = Dispatcher.tool_specs(policy)

    api_messages =
      messages
      |> Session.prepare_for_api(session.context, 24)
      |> inject_policy_message(policy, tools)

    case API.execute(session.client, api_messages, tools, :main) do
      {:ok, %{message: message, raw_response: raw_response}} ->
        Session.log(session, Session.compact_raw_response(raw_response))
        Pretty.print_assistant(message["content"], :main)
        Pretty.print_raw_response(raw_response)

        session =
          if usage = raw_response["usage"] do
            Session.update_usage(session, usage)
          else
            session
          end

        StatusBar.update(pid, session)

        if session.total_tokens >= 150_000 do
          Session.summarize_and_rollover(session, messages ++ [message], pid)
        else
          message = normalize_tool_calls(message)
          compacted_message = Session.compact_for_api(message)
          new_messages = messages ++ [compacted_message]

          if has_tool_calls?(message) do
            {tool_responses, session} =
              Enum.map_reduce(message["tool_calls"], session, fn tool_call, session ->
                name = tool_call["function"]["name"]
                args = decode_tool_args(tool_call["function"]["arguments"])

                content = Dispatcher.execute(name, args, policy)
                print_tool_execution(name, args, content)
                session = update_context(session, name, args, content)

                {
                  %{
                    role: "tool",
                    tool_call_id: tool_call["id"],
                    name: name,
                    content: content
                  },
                  session
                }
              end)

            Enum.each(tool_responses, &Session.log(session, &1))
            process_messages(session, new_messages ++ tool_responses, pid, depth + 1, policy)
          else
            %{session | messages: Session.compact_history(new_messages)}
          end
        end

      {:error, %OpenaiEx.Error{kind: :rate_limit}} ->
        Pretty.print_rate_limit_error()
        session

      {:error, %OpenaiEx.Error{kind: :api_timeout_error}} ->
        Pretty.print_timeout_error()
        session

      {:error, %OpenaiEx.Error{} = error} ->
        Pretty.print_api_error(error)
        session

      {:error, reason} ->
        Pretty.print_error("#{inspect(reason)}")
        session
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

  defp inject_policy_message(messages, policy, tools) do
    policy_message = %{
      role: "system",
      content: policy_summary(policy, tools)
    }

    case messages do
      [system, context | rest] when is_map(system) and is_map(context) ->
        [system, context, policy_message | rest]

      [system | rest] when is_map(system) ->
        [system, policy_message | rest]

      other ->
        [policy_message | other]
    end
  end

  defp policy_summary(policy, tools) do
    tool_names =
      tools
      |> Enum.map(fn tool ->
        get_in(tool, [:function, :name]) || get_in(tool, ["function", "name"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    case Map.get(policy, :mode) do
      :unconfirmed ->
        "Current turn policy: unconfirmed. Exposed tools: #{tool_names}. For file changes, call plan first. Do not call write, edit, patch, fs, image_generation, task, or curl before /confirm or an explicit Policy block."

      :restricted_write ->
        allowed_paths = Enum.join(Map.get(policy, :allowed_write_paths, []), ", ")

        "Current turn policy: restricted_write. Exposed tools: #{tool_names}. Allowed write paths: #{allowed_paths}. Do not call plan."

      :read_only ->
        "Current turn policy: read_only. Exposed tools: #{tool_names}. Do not call mutation or network tools."

      :invalid_policy ->
        "Current turn policy: invalid_policy. Exposed tools: #{tool_names}. Mutation tools are disabled."

      _ ->
        "Current turn policy: development. Exposed tools: #{tool_names}. Follow runtime safety constraints."
    end
  end

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_args), do: %{}

  defp update_context(session, name, args, content),
    do: %{session | context: Context.update_from_tool(session.context, name, args, content)}

  defp print_tool_execution(name, args, "Error: Tool call blocked" <> rest) do
    Pretty.print_blocked_tool_call(name, args, "Tool call blocked" <> rest)
  end

  defp print_tool_execution(name, args, "Error: Mutation requires" <> rest) do
    Pretty.print_blocked_tool_call(name, args, "Mutation requires" <> rest)
  end

  defp print_tool_execution(name, args, "Error: " <> reason) do
    Pretty.print_tool_call(name, args)
    Pretty.print_error(reason)
  end

  defp print_tool_execution(name, args, _content) do
    Pretty.print_tool_call(name, args)
  end
end
