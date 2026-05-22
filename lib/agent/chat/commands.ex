defmodule Beamcore.Agent.Chat.Commands do
  @moduledoc """
  Handles command parsing and execution.
  """

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Core.Pretty

  @doc """
  Handle a command and return the updated session.
  """
  def execute(command, session) do
    case command do
      "new" -> handle_new(session)
      "help" -> handle_help(session)
      _ -> handle_unknown(command, session)
    end
  end

  defp handle_new(session) do
    IO.puts("Starting new session...")

    session.client
    |> Session.new()
    |> then(& &1)
  end

  defp handle_help(session) do
    IO.puts("""
    Available commands:
      /new  - Start a new chat session
      /help - Show this help message
    """)

    session
  end

  defp handle_unknown(command, session) do
    Pretty.print_error("Unknown command: /#{command}")
    session
  end
end
