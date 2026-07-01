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

    base_messages =
      if client || provider_ready?,
        do: [],
        else: [
          %{
            role: :system,
            content:
              "Beamcore is not configured for the selected primary provider. Use /api list or /api add to configure one."
          }
        ]

    messages = base_messages ++ Beamcore.Remote.attach_hint_messages()

    session = Session.new(client, opts)

    %State{
      terminal: terminal,
      textarea: textarea,
      session: session,
      messages: messages,
      last_animation_tick_ms: System.monotonic_time(:millisecond),
      unicode?: Beamcore.TUI.Capability.unicode?(opts),
      provider: session.mode_settings.provider,
      model: session.mode_settings.model,
      history: history,
      history_index: nil,
      history_draft: "",
      memory_total: memory_total,
      screen_type: screen_type
    }
  end

  def compute_memory_total do
    case Beamcore.Memory.overview() do
      %{total: total} when is_integer(total) -> total
      _ -> 0
    end
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

  @doc """
  Build a State from a restored session.

  Converts session messages into display messages for the TUI.
  Skips system prompts and tool_call-only assistant messages.
  """
  def from_restored(session, opts \\ []) do
    display_messages =
      Enum.flat_map(session.messages, fn msg ->
        case msg do
          %{"role" => "system"} ->
            []

          %{"role" => "user", "content" => c} when is_binary(c) ->
            [%{role: :user, content: c}]

          %{"role" => "assistant", "content" => c} when is_binary(c) and c != "" ->
            [%{role: :assistant, content: c}]

          %{"role" => "assistant", "tool_calls" => tc} when is_list(tc) ->
            []

          %{"role" => "assistant", "content" => ""} ->
            []

          %{"role" => "tool", "name" => _n, "content" => c} when is_binary(c) ->
            [%{role: :tool, content: c}]

          _ ->
            []
        end
      end)

    screen_type = Keyword.get(opts, :screen_type, :agent)
    textarea = Keyword.get(opts, :textarea, ExRatatui.textarea_new())

    %State{
      textarea: textarea,
      session: session,
      messages: display_messages,
      last_animation_tick_ms: System.monotonic_time(:millisecond),
      unicode?: true,
      provider: session.mode_settings.provider,
      model: session.mode_settings.model,
      history: Beamcore.TUI.History.load(),
      history_index: nil,
      history_draft: "",
      memory_total: compute_memory_total(),
      screen_type: screen_type
    }
  end
end
