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
    Beamcore.AppLog.info("Application starting", app: :agent)
    remember_initial_workspace()

    children = [
      Beamcore.Config,
      Beamcore.Memory,
      Beamcore.Provider.Scheduler,
      {Task.Supervisor, name: Beamcore.Agent.TaskSupervisor},
      Beamcore.Agent.Tools.Eeva.AtomBudget,
      Beamcore.Agent.Tools.Eeva.Supervisor,
      Beamcore.Provider.Health,
      Beamcore.TUI.DynamicSupervisor
    ]

    opts = [strategy: :one_for_one, name: Beamcore.Agent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def prep_stop(state) do
    Beamcore.AppLog.info("Application shutting down", app: :agent)
    state
  end

  def stop(_state) do
    Beamcore.AppLog.info("Application stopped", app: :agent)
    :ok
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
  Start the primary interactive agent chat experience.
  """
  def chat(opts \\ [])

  def chat(opts) when is_list(opts) do
    with_workspace(opts, fn opts ->
      start_tui(opts)
    end)
  end

  def chat(_mode, opts) when is_list(opts) do
    with_workspace(opts, fn opts ->
      start_tui(opts)
    end)
  end

  defp start_tui(opts),
    do: call_start(Keyword.get(opts, :tui_start, &Beamcore.TUI.start/1), opts)

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
