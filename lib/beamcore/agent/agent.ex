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

  @version Application.spec(:beamcore, :vsn) || "0.1.0"

  @doc """
  CLI entry point for the release executable.

  Handles --help, --version, and defaults to launching the TUI chat.
  """
  def main(args \\ [])

  def main(["--help" | _]), do: print_help()
  def main(["-h" | _]), do: print_help()
  def main(["--version" | _]), do: print_version()
  def main(["-v" | _]), do: print_version()
  def main(_args), do: chat()

  defp print_version do
    IO.puts("beamcore v" <> version())
  end

  defp print_help do
    IO.puts("beamcore v" <> version() <> " \u2014 an autonomous terminal coding agent")
    IO.puts("")
    IO.puts("Usage:")
    IO.puts("  beamcore                Start the interactive TUI chat")
    IO.puts("  beamcore --telegram     Start Telegram bot mode (no TUI)")
    IO.puts("  beamcore --help         Show this help message")
    IO.puts("  beamcore --version      Show version")
    IO.puts("")
    IO.puts("Configuration:")
    IO.puts("  API keys can be set via environment variables or configured")
    IO.puts("  interactively with /api add inside the TUI.")
    IO.puts("")
    IO.puts("  TELEGRAM_BOT_TOKEN  Set to enable Telegram bot mode")
    IO.puts("")
    IO.puts("  See .env.example for available environment variables.")
    IO.puts("")
    IO.puts("Documentation:")
    IO.puts("  https://github.com/beamcore/agent")
  end

  @doc """
  Returns the application version string.
  """
  def version, do: @version

  @doc """
  Start the Beamcore.Agent application.
  """
  def start(_type, _args) do
    Beamcore.AppLog.info("Application starting", app: :beamcore)
    remember_initial_workspace()

    # Ensure we are a distributed Erlang node before starting supervised processes
    Beamcore.Mesh.NodeNaming.ensure_distributed!()

    children =
      [
        Beamcore.Config,
        Beamcore.Memory,
        Beamcore.Provider.Scheduler,
        {Task.Supervisor, name: Beamcore.Agent.TaskSupervisor},
        Beamcore.Agent.Tools.Eeva.AtomBudget,
        Beamcore.Agent.Tools.Eeva.Supervisor,
        Beamcore.Provider.Health,
        Beamcore.Mesh,
        Beamcore.Mesh.Discovery
      ] ++ tui_children() ++ telegram_children()

    opts = [strategy: :one_for_one, name: Beamcore.Agent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def prep_stop(state) do
    Beamcore.AppLog.info("Application shutting down", app: :beamcore)
    state
  end

  def stop(_state) do
    Beamcore.AppLog.info("Application stopped", app: :beamcore)
    :ok
  end

  defp tui_children do
    if telegram_mode?(), do: [], else: [Beamcore.TUI.DynamicSupervisor]
  end

  defp telegram_children do
    case System.get_env("TELEGRAM_BOT_TOKEN") do
      nil -> []
      "" -> []
      token -> [{Beamcore.Telegram, token: token}]
    end
  end

  defp telegram_mode? do
    case System.get_env("TELEGRAM_BOT_TOKEN") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp remember_initial_workspace do
    if is_nil(Application.get_env(:beamcore, :initial_workspace_root)) do
      case File.cwd() do
        {:ok, cwd} -> Application.put_env(:beamcore, :initial_workspace_root, Path.expand(cwd))
        {:error, _reason} -> :ok
      end
    end
  end

  @doc """
  Start the primary interactive agent chat experience.
  """
  def chat(opts \\ [])

  def chat(opts) when is_list(opts) do
    if telegram_mode?() do
      IO.puts("BeamCore Telegram bot mode. Press Ctrl+C to stop.")
      Process.sleep(:infinity)
    else
      with_workspace(opts, fn opts ->
        start_tui(opts)
      end)
    end
  end

  def chat(_mode, opts) when is_list(opts) do
    if telegram_mode?() do
      IO.puts("BeamCore Telegram bot mode. Press Ctrl+C to stop.")
      Process.sleep(:infinity)
    else
      with_workspace(opts, fn opts ->
        start_tui(opts)
      end)
    end
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
