defmodule Beamcore.Agent do
  @moduledoc """
  Main application module for Beamcore.Agent.

  This module serves as the entry point for the Beamcore.Agent application,
  providing core functionality such as:
  - Application lifecycle management (start/stop)
  - Access to the OpenAI client
  - Interactive chat session initialization
  - API connectivity testing

  It supervises child processes like the rate limiter and status bar,
  ensuring the application's components are properly managed.
  """

  use Application

  @doc """
  Start the Beamcore.Agent application.
  """
  def start(_type, _args) do
    children = [
      Beamcore.Agent.Chat.RateLimiter,
      Beamcore.Agent.Core.StatusBar
    ]

    opts = [strategy: :one_for_one, name: Beamcore.Agent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Get the OpenAI client.
  """
  def client, do: Beamcore.Agent.OpenAI.client()

  @doc """
  Make a test API call to verify the client works.
  """
  def test_api_call do
    client = Beamcore.Agent.OpenAI.client()
    IO.puts("OpenAI client configured successfully:")
    IO.inspect(client)
  end

  @doc """
  Start an interactive chat session.
  """
  def chat do
    Beamcore.Agent.Chat.start()
  end
end
