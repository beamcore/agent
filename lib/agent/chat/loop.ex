defmodule Beamcore.Agent.Chat.Loop do
  @moduledoc """
  Handles the chat loop and user input.
  """

  alias Beamcore.Agent.Chat.{API, Commands, Session}
  alias Beamcore.Agent.Core.{Pretty, StatusBar}
  alias Beamcore.Agent.Tools.Dispatcher

  @max_tool_depth 25

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
    user_message = %{role: "user", content: content}
    Session.log(session, user_message)

    messages = session.messages ++ [user_message]
    process_messages(session, messages, pid)
  end

  defp process_messages(session, messages, pid, depth \\ 0)

  defp process_messages(session, messages, _pid, depth) when depth >= @max_tool_depth do
    Pretty.print_warning("Tool loop depth limit (#{@max_tool_depth}) reached. Stopping.")
    %{session | messages: messages}
  end

  defp process_messages(session, messages, pid, depth) do
    tools = Dispatcher.conductor_tool_specs()

    case API.execute(session.client, messages, tools, :main) do
      {:ok, %{message: message, raw_response: raw_response}} ->
        Session.log(session, raw_response)
        Pretty.print_assistant(message["content"], :main)
        Pretty.print_raw_response(raw_response)

        # Update token usage if present in the response
        session =
          if usage = raw_response["usage"] do
            Session.update_usage(session, usage)
          else
            session
          end

        StatusBar.update(pid, session)

        if session.total_tokens >= 190_000 do
          Session.summarize_and_rollover(session, messages ++ [message], pid)
        else
          # Fix tool_calls for subsequent API requests
          message =
            if message["tool_calls"] do
              fixed_tool_calls =
                Enum.map(message["tool_calls"], fn tc ->
                  tc
                  |> Map.put("type", "function")
                  |> Map.delete("index")
                end)

              Map.put(message, "tool_calls", fixed_tool_calls)
            else
              message
            end

          new_messages = messages ++ [message]

          if message["tool_calls"] && message["tool_calls"] != [] do
            tool_responses =
              Enum.map(message["tool_calls"], fn tool_call ->
                name = tool_call["function"]["name"]
                args_str = tool_call["function"]["arguments"]

                args =
                  case Jason.decode(args_str) do
                    {:ok, decoded} -> decoded
                    _ -> %{}
                  end

                content = Dispatcher.execute(name, args)

                %{
                  role: "tool",
                  tool_call_id: tool_call["id"],
                  name: name,
                  content: content
                }
              end)

            Enum.each(tool_responses, &Session.log(session, &1))
            process_messages(session, new_messages ++ tool_responses, pid, depth + 1)
          else
            %{session | messages: new_messages}
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
end
