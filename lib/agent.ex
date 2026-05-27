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
    maybe_connect_ledger_node()

    children = [
      Beamcore.Ledger,
      Beamcore.Memory,
      Beamcore.Agent.Chat.RateLimiter,
      Beamcore.Agent.Core.StatusBar
    ]

    opts = [strategy: :one_for_one, name: Beamcore.Agent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_connect_ledger_node do
    case System.get_env("LEDGER_NODE") do
      nil ->
        :ok

      node_str ->
        node_atom = String.to_atom(node_str)

        case Node.connect(node_atom) do
          true ->
            Process.sleep(100)
            :ok

          false ->
            :ok
        end
    end
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
  Start the primary interactive agent chat experience.
  """
  def chat(mode \\ :auto, opts \\ [])

  def chat(:auto, opts) do
    if Beamcore.Agent.TUI.Capability.supported?(opts) do
      start_tui(opts)
    else
      fallback_to_plain(Beamcore.Agent.TUI.Capability.unsupported_reason(opts), opts)
    end
  rescue
    error ->
      fallback_to_plain(Exception.message(error), opts)
  end

  def chat(:tui, opts), do: start_tui(opts)
  def chat(:plain, opts), do: start_plain(opts)
  def chat(:classic, opts), do: chat(:plain, opts)

  @doc false
  def chat_mode(opts \\ []) do
    if Beamcore.Agent.TUI.Capability.supported?(opts), do: :tui, else: :plain
  end

  defp fallback_to_plain(reason, opts) do
    IO.puts("TUI unavailable: #{reason}")
    IO.puts("Starting plain emergency fallback.")
    start_plain(opts)
  end

  defp start_tui(opts),
    do: call_start(Keyword.get(opts, :tui_start, &Beamcore.Agent.TUI.start/1), opts)

  defp start_plain(opts),
    do: call_start(Keyword.get(opts, :plain_start, &Beamcore.Agent.Chat.start/0), opts)

  defp call_start(fun, opts) when is_function(fun, 1), do: fun.(opts)
  defp call_start(fun, _opts) when is_function(fun, 0), do: fun.()
end
