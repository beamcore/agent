defmodule Beamcore.Gateway.SessionStore do
  @moduledoc """
  ETS-backed per-chat session state.

  Pure state management — no tasks, no events. Adapters own the task lifecycle.
  """

  use GenServer

  @table :gateway_sessions
  @idle_timeout_ms 4 * 60 * 60 * 1000
  @cleanup_interval_ms 60_000

  defstruct [:session, :chat_key, :platform, :task_ref, :queue, :last_active]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def get(chat_key) do
    case :ets.lookup(@table, chat_key) do
      [{^chat_key, state}] -> {:ok, state}
      [] -> :not_found
    end
  end

  def get_or_create(chat_key, platform) do
    case get(chat_key) do
      {:ok, state} ->
        touch(state)

      :not_found ->
        state = %__MODULE__{
          session: new_session(chat_key),
          chat_key: chat_key,
          platform: platform,
          task_ref: nil,
          queue: :empty,
          last_active: now_ms()
        }

        :ets.insert(@table, {chat_key, state})
        {:ok, state}
    end
  end

  def put(chat_key, %__MODULE__{} = state) do
    :ets.insert(@table, {chat_key, %{state | last_active: now_ms()}})
    :ok
  end

  def reset(chat_key) do
    case get(chat_key) do
      {:ok, state} ->
        new = %{
          state
          | session: new_session(chat_key),
            task_ref: nil,
            queue: :empty,
            last_active: now_ms()
        }

        :ets.insert(@table, {chat_key, new})
        :ok

      :not_found ->
        :not_found
    end
  end

  def busy?(chat_key) do
    case get(chat_key) do
      {:ok, %{task_ref: ref}} when ref != nil -> true
      _ -> false
    end
  end

  def queue_message(chat_key, text) do
    case get(chat_key) do
      {:ok, state} ->
        :ets.insert(@table, {chat_key, %{state | queue: {:pending, text}, last_active: now_ms()}})
        :ok

      :not_found ->
        {:error, :not_found}
    end
  end

  def dequeue_message(chat_key) do
    case get(chat_key) do
      {:ok, %{queue: {:pending, text}} = state} ->
        :ets.insert(@table, {chat_key, %{state | queue: :empty, last_active: now_ms()}})
        {:ok, text}

      _ ->
        :empty
    end
  end

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = now_ms() - @idle_timeout_ms

    :ets.select_delete(@table, [
      {{:_, %{last_active: :"$1", task_ref: nil}}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp touch(state) do
    new = %{state | last_active: now_ms()}
    :ets.insert(@table, {state.chat_key, new})
    {:ok, new}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  defp new_session(chat_key) do
    Beamcore.Agent.Chat.Session.new(nil,
      screen_type: :chat,
      session_id: "gw-#{chat_key}-#{System.system_time(:second)}"
    )
  end

  defp now_ms, do: System.system_time(:millisecond)
end
