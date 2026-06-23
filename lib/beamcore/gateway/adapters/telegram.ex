defmodule Beamcore.Gateway.Adapters.Telegram do
  @moduledoc """
  Telegram adapter: polling, typing, rate limiting, allowlist.
  Delegates commands and turn logic to Gateway.Commands and Gateway.Turn.
  """

  use GenServer

  alias Beamcore.Gateway.{Commands, Turn}

  @poll_timeout 5
  @rate_limit_seconds 3
  @rate_limit_cleanup_ms 300_000
  @max_message_chars 4096

  defstruct [:client, :offset, :rate_table, :allowed_users]

  # -- GenServer ---------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    client = Nadia.Client.new(token: token)
    rate_table = :ets.new(:tg_rate_limit, [:set, :private])
    allowed_users = load_allowed_users()

    case Nadia.get_me(client) do
      {:ok, bot} ->
        Beamcore.AppLog.info("Telegram adapter: @#{bot.username}")
        register_commands(client)
        Process.send_after(self(), :cleanup_rate, @rate_limit_cleanup_ms)
        send(self(), :poll)

        {:ok,
         %__MODULE__{
           client: client,
           offset: 0,
           rate_table: rate_table,
           allowed_users: allowed_users
         }}

      {:error, error} ->
        {:stop, {:telegram_auth_failed, error}}
    end
  end

  # -- Poll loop ---------------------------------------------------------------

  @impl true
  def handle_info(:poll, state) do
    send(self(), :poll)
    {:noreply, %{state | offset: poll_once(state)}}
  end

  @impl true
  def handle_info(:cleanup_rate, state) do
    now = System.system_time(:second)

    :ets.select_delete(state.rate_table, [
      {{:_, {:_, :"$1"}}, [{:<, :"$1", now - @rate_limit_seconds * 10}], [true]}
    ])

    Process.send_after(self(), :cleanup_rate, @rate_limit_cleanup_ms)
    {:noreply, state}
  end

  # -- Gateway events ----------------------------------------------------------

  @impl true
  def handle_info({:gateway_event, chat_key, event}, state) do
    case Turn.format_event(event) do
      {:text, text} ->
        send_text(state.client, chat_key, text)

      {:code, code} ->
        send_text(state.client, chat_key, "```\n#{code}\n```", parse_mode: "Markdown")

      {:error_code, code} ->
        send_text(state.client, chat_key, "Error:\n```\n#{code}\n```", parse_mode: "Markdown")

      {:error, msg} ->
        send_text(state.client, chat_key, "Error: #{msg}")

      :typing ->
        send_typing(state.client, chat_key)

      :ignore ->
        :ok
    end

    {:noreply, state}
  end

  # -- Task result -------------------------------------------------------------

  @impl true
  def handle_info({ref, session}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Turn.handle_result(ref, session) do
      {:ok, chat_key} ->
        typing_fn = fn -> send_typing(state.client, chat_key) end
        Turn.process_queue(chat_key, typing_fn)

      :not_found ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Turn.handle_failure(ref, reason) do
      {:ok, chat_key, reason} ->
        if reason != :normal, do: send_text(state.client, chat_key, "Error: #{inspect(reason)}")
        typing_fn = fn -> send_typing(state.client, chat_key) end
        Turn.process_queue(chat_key, typing_fn)

      :not_found ->
        :ok
    end

    {:noreply, state}
  end

  # -- Update dispatch ---------------------------------------------------------

  defp poll_once(state) do
    case Nadia.get_updates(state.client, offset: state.offset, timeout: @poll_timeout) do
      {:ok, updates} when is_list(updates) ->
        Enum.each(updates, &handle_update(&1, state))

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

  defp handle_update(%{message: %{text: text, chat: chat, from: from}}, state)
       when is_binary(text) and text != "" do
    chat_key = "telegram:#{chat.id}"
    user_id = to_string(from.id)

    cond do
      text == "/myid" ->
        send_text(state.client, chat_key, "Your Telegram ID: #{user_id}")

      not allowed?(state, user_id) ->
        send_text(
          state.client,
          chat_key,
          "Access denied.\nYour ID: #{user_id}\n\nAdd to TELEGRAM_ALLOWED_USERS."
        )

      true ->
        handle_routed(text, chat_key, state)
    end
  end

  defp handle_update(_, _), do: :ok

  defp handle_routed(text, chat_key, state) do
    case Commands.route(text, chat_key) do
      {:command, :cancel} ->
        case Turn.cancel(chat_key) do
          :ok -> send_text(state.client, chat_key, "Stopped.")
          :not_running -> send_text(state.client, chat_key, "Nothing running.")
        end

      {:command, response} ->
        send_text(state.client, chat_key, response)

      {:api, parts} ->
        send_text(state.client, chat_key, Commands.exec_api(parts))

      {:message, text} ->
        if rate_limited?(state.rate_table, chat_key) do
          remaining = remaining_seconds(state.rate_table, chat_key)
          send_text(state.client, chat_key, "Rate limited. Wait #{remaining}s.")
        else
          update_rate_limit(state.rate_table, chat_key)
          typing_fn = fn -> send_typing(state.client, chat_key) end
          Turn.dispatch(chat_key, :telegram, text, &send_text(state.client, &1, &2), typing_fn)
        end
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp send_text(client, "telegram:" <> chat_id, text, opts \\ []) do
    case Nadia.send_message(
           client,
           String.to_integer(chat_id),
           String.slice(text, 0, @max_message_chars),
           opts
         ) do
      {:ok, _} -> :ok
      {:error, e} -> Beamcore.AppLog.warn("Telegram send failed: #{inspect(e)}")
    end
  end

  defp send_typing(client, "telegram:" <> chat_id) do
    Nadia.send_chat_action(client, String.to_integer(chat_id), "typing")
  end

  # -- Security ----------------------------------------------------------------

  defp load_allowed_users do
    case System.get_env("TELEGRAM_ALLOWED_USERS") do
      nil -> nil
      "" -> nil
      ids -> ids |> String.split(",") |> Enum.map(&String.trim/1) |> MapSet.new()
    end
  end

  defp allowed?(%{allowed_users: nil}, _user_id), do: true
  defp allowed?(%{allowed_users: users}, user_id), do: MapSet.member?(users, user_id)

  # -- Rate limiting -----------------------------------------------------------

  defp rate_limited?(table, key) do
    case :ets.lookup(table, key) do
      [{_, {ts, _}}] -> System.system_time(:second) - ts < @rate_limit_seconds
      [] -> false
    end
  end

  defp remaining_seconds(table, key) do
    case :ets.lookup(table, key) do
      [{_, {ts, _}}] -> max(0, @rate_limit_seconds - (System.system_time(:second) - ts))
      [] -> 0
    end
  end

  defp update_rate_limit(table, key) do
    :ets.insert(table, {key, {System.system_time(:second), 1}})
  end

  # -- Commands ----------------------------------------------------------------

  defp register_commands(client) do
    Nadia.set_my_commands(client, [
      %{"command" => "new", "description" => "Start a new session"},
      %{"command" => "api", "description" => "Configure LLM provider"},
      %{"command" => "status", "description" => "Show session info"},
      %{"command" => "myid", "description" => "Show your Telegram ID"},
      %{"command" => "stop", "description" => "Stop current task"},
      %{"command" => "help", "description" => "Show help"}
    ])
  end
end
