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
    remember_initial_workspace()

    children = [
      Beamcore.Config,
      Beamcore.Memory,
      Beamcore.RateLimiter,
      Beamcore.Provider.Scheduler,
      {Task.Supervisor, name: Beamcore.Agent.TaskSupervisor},
      Beamcore.Agent.Tools.Eeva.AtomBudget,
      Beamcore.Agent.Tools.Eeva.Supervisor,
      Beamcore.Provider.Health,
      Beamcore.Agent.Core.StatusBar,
      Beamcore.TUI.DynamicSupervisor
    ]

    opts = [strategy: :one_for_one, name: Beamcore.Agent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp remember_initial_workspace do
    if is_nil(Application.get_env(:agent, :initial_workspace_root)) do
      case File.cwd() do
        {:ok, cwd} -> Application.put_env(:agent, :initial_workspace_root, Path.expand(cwd))
        {:error, _reason} -> :ok
      end
    end
  end

  @doc """
  Returns an OpenaiEx client for the active provider.
  """
  def client, do: Beamcore.Provider.Registry.client()

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
        do: (:ok -> start_tui(opts))
    end)
  end

  def chat(:plain, opts) do
    with_workspace(opts, fn opts ->
      case ensure_chat_config(opts),
        do: (:ok -> start_plain(opts))
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

      true ->
        case Beamcore.Provider.Registry.validate_selection(Beamcore.Config.active_provider()) do
          {:ok, _provider} ->
            :ok

          {:error, _reason} ->
            print_missing_config_error()
            :ok
        end
    end
  end

  defp missing_config_reason?(reason) when is_binary(reason),
    do:
      String.contains?(reason, "MISTRAL_API_KEY environment variable is required") or
        String.contains?(reason, "Beamcore is not configured yet")

  defp print_missing_config_error do
    IO.puts(Beamcore.Provider.Registry.missing_config_message())
    {:error, :missing_config}
  end

  defp start_tui(opts),
    do: call_start(Keyword.get(opts, :tui_start, &Beamcore.TUI.start/1), opts)

  defp start_plain(opts),
    do: call_start(Keyword.get(opts, :plain_start, &Beamcore.Agent.Chat.start/1), opts)

  defp call_start(fun, opts) when is_function(fun, 1), do: fun.(opts)
  defp call_start(fun, _opts) when is_function(fun, 0), do: fun.()

  defp with_workspace(opts, fun) do
    default_root =
      case File.cwd() do
        {:ok, cwd} -> cwd
        {:error, _} -> System.user_home!()
      end

    workspace_root =
      opts
      |> Keyword.get(:workspace_root, default_root)
      |> Beamcore.Agent.Tools.PathInput.canonical_path()

    previous = Beamcore.Agent.Tools.PathInput.configure_workspace_root(workspace_root)
    opts = Keyword.put(opts, :workspace_root, workspace_root)

    try do
      fun.(opts)
    after
      Beamcore.Agent.Tools.PathInput.restore_workspace_root(previous)
    end
  end
end
