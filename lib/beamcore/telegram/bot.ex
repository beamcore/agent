defmodule Beamcore.Telegram.Bot do
  @moduledoc """
  Telegram bot with long polling, rate limiting, and command handling.
  """

  use GenServer

  alias Beamcore.Config
  alias Beamcore.Provider.Registry
  alias Beamcore.Telegram.SessionManager
  alias Beamcore.Telegram.SessionWorker

  @poll_timeout 30
  @rate_limit_seconds 3
  @rate_limit_cleanup_interval 300_000

  defstruct [:client, :offset, :rate_table]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    client = Nadia.Client.new(token: token)

    rate_table = :ets.new(:tg_rate_limit, [:set, :private])

    Process.send_after(self(), :cleanup_rate_table, @rate_limit_cleanup_interval)

    case Nadia.get_me(client) do
      {:ok, user} ->
        Beamcore.AppLog.info("Telegram bot started: @#{user.username}")
        set_bot_commands(client)

        send(self(), :poll)
        {:ok, %__MODULE__{client: client, offset: 0, rate_table: rate_table}}

      {:error, error} ->
        {:stop, {:telegram_auth_failed, error}}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    new_offset = poll_once(state)
    send(self(), :poll)
    {:noreply, %{state | offset: new_offset}}
  end

  @impl true
  def handle_info(:cleanup_rate_table, state) do
    now = System.system_time(:second)

    :ets.select_delete(state.rate_table, [
      {{:_, {:_, :"$1"}}, [{:<, :"$1", now - @rate_limit_seconds * 10}], [true]}
    ])

    Process.send_after(self(), :cleanup_rate_table, @rate_limit_cleanup_interval)
    {:noreply, state}
  end

  defp poll_once(state) do
    case Nadia.get_updates(state.client, offset: state.offset, timeout: @poll_timeout) do
      {:ok, updates} when is_list(updates) ->
        Enum.each(updates, fn update -> handle_update(update, state) end)

        case List.last(updates) do
          nil -> state.offset
          last -> last.update_id + 1
        end

      {:error, error} ->
        Beamcore.AppLog.warn("Telegram poll error: #{inspect(error)}")
        Process.sleep(1000)
        state.offset
    end
  end

  defp handle_update(%{message: %{text: text, chat: chat, from: from}} = _update, state)
       when is_binary(text) and text != "" do
    chat_id = chat.id
    user_id = from.id

    cond do
      text == "/start" ->
        Nadia.send_message(state.client, chat_id, welcome_message())

      text == "/reset" ->
        case SessionManager.get_or_create(state.client, chat_id, user_id) do
          {:ok, pid} -> SessionWorker.reset(pid)
          {:error, _} -> Nadia.send_message(state.client, chat_id, "Failed to reset session.")
        end

      text == "/help" ->
        Nadia.send_message(state.client, chat_id, help_message())

      text == "/status" ->
        Nadia.send_message(state.client, chat_id, status_message())

      text == "/api" ->
        Nadia.send_message(state.client, chat_id, api_help_message())

      String.starts_with?(text, "/api ") ->
        handle_api_command(String.trim_leading(text, "/api "), chat_id, state)

      String.starts_with?(text, "/") ->
        Nadia.send_message(state.client, chat_id, "Unknown command. Type /help")

      rate_limited?(state.rate_table, user_id) ->
        remaining = remaining_seconds(state.rate_table, user_id)

        Nadia.send_message(
          state.client,
          chat_id,
          "Rate limited. Try again in #{remaining}s."
        )

      true ->
        update_rate_limit(state.rate_table, user_id)

        case SessionManager.get_or_create(state.client, chat_id, user_id) do
          {:ok, pid} ->
            SessionWorker.send_message(pid, text)

          {:error, reason} ->
            Beamcore.AppLog.warn("Session start failed: #{inspect(reason)}")

            Nadia.send_message(
              state.client,
              chat_id,
              "Failed to start agent session."
            )
        end
    end
  end

  defp handle_update(_update, _state), do: :ok

  # -- /api command handling ------------------------------------------------

  defp handle_api_command(args, chat_id, state) do
    parts = String.split(args, " ", trim: true)

    case parts do
      ["add", name, key] ->
        add_provider(name, key, nil, nil, chat_id, state)

      ["add", name, key, base_url] ->
        add_provider(name, key, base_url, nil, chat_id, state)

      ["add", name, key, base_url, model] ->
        add_provider(name, key, base_url, model, chat_id, state)

      ["list"] ->
        Nadia.send_message(state.client, chat_id, list_providers_message())

      ["set", name] ->
        case Registry.get(name) do
          nil ->
            Nadia.send_message(state.client, chat_id, "Unknown provider: #{name}")

          _ ->
            Config.set_active_provider(name)
            Nadia.send_message(state.client, chat_id, "Active provider set to: #{name}")
        end

      _ ->
        Nadia.send_message(state.client, chat_id, api_help_message())
    end
  end

  defp add_provider(name, key, base_url, model, chat_id, state) do
    config =
      %{"api_key" => key}
      |> maybe_put("base_url", base_url)
      |> maybe_put("default_model", model)

    case Config.put_provider(name, config) do
      :ok ->
        Config.set_active_provider(name)
        Nadia.send_message(state.client, chat_id, "Provider '#{name}' configured and activated!")

      {:error, reason} ->
        Nadia.send_message(state.client, chat_id, "Failed to save: #{inspect(reason)}")
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp list_providers_message do
    providers = Registry.list()

    lines =
      Enum.map(providers, fn p ->
        status = if p.configured?, do: "configured", else: "not configured"
        active = if p.active?, do: " [ACTIVE]", else: ""
        "  #{p.name} - #{status}#{active}"
      end)

    "Providers:\n#{Enum.join(lines, "\n")}"
  end

  # -- Messages -------------------------------------------------------------

  defp rate_limited?(table, user_id) do
    case :ets.lookup(table, user_id) do
      [{_, {last_ts, _count}}] ->
        System.system_time(:second) - last_ts < @rate_limit_seconds

      [] ->
        false
    end
  end

  defp remaining_seconds(table, user_id) do
    case :ets.lookup(table, user_id) do
      [{_, {last_ts, _count}}] ->
        max(0, @rate_limit_seconds - (System.system_time(:second) - last_ts))

      [] ->
        0
    end
  end

  defp update_rate_limit(table, user_id) do
    now = System.system_time(:second)
    :ets.insert(table, {user_id, {now, 1}})
  end

  defp set_bot_commands(client) do
    commands = [
      %{"command" => "start", "description" => "Start the bot"},
      %{"command" => "reset", "description" => "Reset agent session"},
      %{"command" => "status", "description" => "Show current config"},
      %{"command" => "api", "description" => "Configure LLM provider"},
      %{"command" => "help", "description" => "Show help"}
    ]

    case Nadia.set_my_commands(client, commands) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp status_message do
    provider = Config.active_provider() || "not set"
    model = Config.active_model(:chat) || "default"

    providers = Registry.list()
    configured = Enum.filter(providers, & &1.configured?)
    configured_names = Enum.map(configured, & &1.name) |> Enum.join(", ")

    """
    BeamCore Status

    Active provider: #{provider}
    Active model: #{model}
    Configured providers: #{configured_names || "none"}

    Use /api to configure a provider.
    """
  end

  defp api_help_message do
    """
    API Configuration

    /api add <name> <key> [base_url] [model]
      Add and activate a provider.

      Examples:
      /api add deepseek sk-xxx123
      /api add openai sk-xxx123
      /api add groq gsk_xxx123 https://api.groq.com/openai/v1 llama-3.3-70b-versatile
      /api add ollama ollama http://localhost:11434/v1 llama3

    /api list
      Show all providers and their status.

    /api set <name>
      Switch active provider.

    Cheap/Free providers:
      DeepSeek - https://platform.deepseek.com (~$0.14/M tokens)
      Groq     - https://console.groq.com (free tier, fast)
      Ollama   - https://ollama.ai (free, local, no API key needed)
    """
  end

  defp welcome_message do
    """
    Welcome to BeamCore Agent!

    I am a coding agent that can write and execute code,
    work with files, and perform tasks.

    First time? Set up a provider:
    /api add deepseek sk-your-key-here

    Then just send me a message!

    Commands:
    /start  - This message
    /reset  - Reset session
    /status - Show current config
    /api    - Configure LLM provider
    /help   - Help
    """
  end

  defp help_message do
    """
    BeamCore Agent - Telegram Interface

    Send me any message and I will process it.
    I can execute Elixir code, work with files, etc.

    Commands:
    /start  - Welcome message
    /reset  - Clear session, start fresh
    /status - Show current provider/model
    /api    - Configure LLM provider
    /help   - This message

    Setup:
    1. Get API key from a provider
    2. Send: /api add <provider> <key>
    3. Start chatting!

    Rate limit: 1 message per #{@rate_limit_seconds} seconds.
    """
  end
end
