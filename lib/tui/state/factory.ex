defmodule Beamcore.TUI.State.Factory do
  @moduledoc false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.State

  def new(terminal, textarea, opts \\ []) do
    client = client(opts)
    history = Keyword.get(opts, :history, Beamcore.TUI.History.load())

    memory_total = compute_memory_total()
    screen_type = Keyword.get(opts, :screen_type, :agent)

    provider_ready? = primary_provider_ready?(screen_type)

    messages =
      if client || provider_ready?,
        do: [],
        else: [
          %{
            role: :system,
            content:
              "Beamcore is not configured for the selected primary provider. Use /api list or /api add to configure one."
          }
        ]

    %State{
      terminal: terminal,
      textarea: textarea,
      session: Session.new(client, opts),
      messages: messages,
      last_animation_tick_ms: System.monotonic_time(:millisecond),
      unicode?: Beamcore.TUI.Capability.unicode?(opts),
      history: history,
      history_index: nil,
      history_draft: "",
      memory_total: memory_total,
      screen_type: screen_type
    }
  end

  def compute_memory_total do
    {org, repo} = Beamcore.Memory.detect_org_repo()

    [:repo_map, :patterns, :decisions, :errors, :context]
    |> Enum.map(fn type -> length(Beamcore.Memory.list(org, repo, type)) end)
    |> Enum.sum()
  end

  defp client(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, client} -> client
      :error -> nil
    end
  end

  defp primary_provider_ready?(screen_type) do
    settings = Beamcore.Agent.Chat.ModeSettings.resolve(screen_type)

    case Beamcore.Provider.Registry.validate_selection(settings.provider) do
      {:ok, _provider} -> true
      _ -> false
    end
  end
end
