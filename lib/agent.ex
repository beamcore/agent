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
      Beamcore.RateLimiter,
      {Task.Supervisor, name: Beamcore.Agent.TaskSupervisor},
      Beamcore.Agent.Core.StatusBar,
      Beamcore.TUI.DynamicSupervisor,
      Beamcore.FileMutationQueue,
      Beamcore.Alignment
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
  def client, do: Beamcore.OpenAI.client()

  @doc """
  Make a test API call to verify the client works.
  """
  def test_api_call do
    client = Beamcore.OpenAI.client()
    IO.puts("OpenAI client configured successfully:")
    IO.inspect(client)
  end

  @doc """
  Start the primary interactive agent chat experience.
  """
  def chat(mode \\ :auto, opts \\ [])

  def chat(:auto, opts) do
    with_workspace(opts, fn opts ->
      try do
        case ensure_chat_config(opts) do
          :ok ->
            if Beamcore.TUI.Capability.supported?(opts) do
              start_tui(opts)
            else
              fallback_to_plain(Beamcore.TUI.Capability.unsupported_reason(opts), opts)
            end
        end
      rescue
        error ->
          reason = Exception.message(error)

          if missing_config_reason?(reason) do
            print_missing_config_error()
          else
            fallback_to_plain(reason, opts)
          end
      end
    end)
  end

  def chat(:tui, opts) do
    with_workspace(opts, fn opts ->
      case ensure_chat_config(opts),
        do: (
          :ok -> start_tui(opts)
        )
    end)
  end

  def chat(:plain, opts) do
    with_workspace(opts, fn opts ->
      case ensure_chat_config(opts),
        do: (
          :ok -> start_plain(opts)
        )
    end)
  end

  def chat(:classic, opts), do: chat(:plain, opts)

  @doc false
  def chat_mode(opts \\ []) do
    if Beamcore.TUI.Capability.supported?(opts), do: :tui, else: :plain
  end

  defp fallback_to_plain(reason, opts) do
    IO.puts("TUI unavailable: #{reason}")
    IO.puts("Starting plain emergency fallback.")
    start_plain(opts)
  end

  defp ensure_chat_config(opts) do
    cond do
      Keyword.has_key?(opts, :client) ->
        :ok

      Beamcore.OpenAI.configured?() ->
        :ok

      true ->
        print_missing_config_error()
        :ok
    end
  end

  defp missing_config_reason?(reason) when is_binary(reason),
    do:
      String.contains?(reason, "MISTRAL_API_KEY environment variable is required") or
        String.contains?(reason, "Beamcore is not configured yet")

  defp print_missing_config_error do
    IO.puts("""
    Beamcore is not configured yet.

    Run /login and paste your Mistral API key (stored securely as hash).

    For development only, you may also set MISTRAL_API_KEY or use .env with make chat.
    """)

    {:error, :missing_config}
  end

  defp start_tui(opts),
    do: call_start(Keyword.get(opts, :tui_start, &Beamcore.TUI.start/1), opts)

  defp start_plain(opts),
    do: call_start(Keyword.get(opts, :plain_start, &Beamcore.Agent.Chat.start/1), opts)

  defp call_start(fun, opts) when is_function(fun, 1), do: fun.(opts)
  defp call_start(fun, _opts) when is_function(fun, 0), do: fun.()

  defp with_workspace(opts, fun) do
    workspace_root =
      opts
      |> Keyword.get(:workspace_root, File.cwd!())
      |> Beamcore.Agent.Tools.PathSafety.canonical_path()

    previous = Beamcore.Agent.Tools.PathSafety.configure_workspace_root(workspace_root)
    opts = Keyword.put(opts, :workspace_root, workspace_root)

    try do
      fun.(opts)
    after
      Beamcore.Agent.Tools.PathSafety.restore_workspace_root(previous)
    end
  end
end
