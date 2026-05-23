defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{API, Commands, Session, ToolPolicy}
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
            new_session = Commands.execute(command, session)
            loop(new_session, pid)

          trimmed ->
            new_session = send_message(session, trimmed, pid)
            loop(new_session, pid)
        end

      _ ->
        :ok
    end
  end

  defp send_message(session, content, pid) do
    policy = ToolPolicy.from_user_message(content)
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
    api_messages = Session.prepare_for_api(messages)

    case API.execute(session.client, api_messages, tools, :main) do
      {:ok, %{message: message, raw_response: raw_response}} ->
        Session.log(session, raw_response)
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
          new_messages = messages ++ [message]

          if has_tool_calls?(message) do
            tool_responses =
              Enum.map(message["tool_calls"], fn tool_call ->
                name = tool_call["function"]["name"]
                args = decode_tool_args(tool_call["function"]["arguments"])

                content = Dispatcher.execute(name, args, policy)

                %{
                  role: "tool",
                  tool_call_id: tool_call["id"],
                  name: name,
                  content: content
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

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_args), do: %{}
end
