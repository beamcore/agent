defmodule Beamcore.Telegram.SessionWorker do
  @moduledoc """
  Per-user GenServer that holds an agent Session and processes messages
  via Loop.send_message in a supervised Task.
  """

  use GenServer

  alias Beamcore.Agent.Chat.{Loop, Session}

  @max_message_chars 4096

  defstruct [:session, :chat_id, :user_id, :client, :task_ref]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_message(pid, text) do
    GenServer.cast(pid, {:send_message, text})
  end

  def reset(pid) do
    GenServer.cast(pid, :reset)
  end

  def busy?(pid) do
    GenServer.call(pid, :busy?)
  end

  @impl true
  def init(opts) do
    client = Keyword.fetch!(opts, :client)
    chat_id = Keyword.fetch!(opts, :chat_id)
    user_id = Keyword.fetch!(opts, :user_id)

    session = new_session(user_id)

    {:ok,
     %__MODULE__{
       session: session,
       chat_id: chat_id,
       user_id: user_id,
       client: client,
       task_ref: nil
     }}
  end

  @impl true
  def handle_cast({:send_message, _text}, %{task_ref: ref} = state) when ref != nil do
    send_reply(state.client, state.chat_id, "Still processing previous request, please wait...")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_message, text}, state) do
    parent = self()
    client = state.client
    chat_id = state.chat_id

    task =
      Task.Supervisor.async_nolink(Beamcore.Agent.TaskSupervisor, fn ->
        send_chat_action(client, chat_id, "typing")

        Loop.send_message(state.session, text, nil,
          event_handler: fn event ->
            send(parent, {:tg_event, event})
          end
        )
      end)

    {:noreply, %{state | task_ref: task.ref}}
  end

  @impl true
  def handle_cast(:reset, state) do
    if state.task_ref do
      send_reply(state.client, state.chat_id, "Session reset after current turn completes.")
      {:noreply, state}
    else
      session = new_session(state.user_id)
      send_reply(state.client, state.chat_id, "Session reset. Starting fresh.")
      {:noreply, %{state | session: session}}
    end
  end

  @impl true
  def handle_call(:busy?, _from, state) do
    {:reply, state.task_ref != nil, state}
  end

  @impl true
  def handle_info({ref, updated_session}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | session: updated_session, task_ref: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    if reason != :normal do
      send_reply(state.client, state.chat_id, "Error: #{inspect(reason)}")
    end

    {:noreply, %{state | task_ref: nil}}
  end

  @impl true
  def handle_info({:tg_event, event}, state) do
    handle_agent_event(event, state)
    {:noreply, state}
  end

  defp handle_agent_event({:assistant, content}, state)
       when is_binary(content) and content != "" do
    send_reply(state.client, state.chat_id, content)
  end

  defp handle_agent_event({:tool_running, "eeva", %{code: code}}, state) do
    preview = String.slice(code, 0, 200)

    send_reply(state.client, state.chat_id, "Executing code:\n```\n#{preview}\n```",
      parse_mode: "Markdown"
    )
  end

  defp handle_agent_event({:tool_finished, "eeva", _args, result_json}, state) do
    case Jason.decode(result_json) do
      {:ok, %{"ok" => true, "stdout" => stdout}} when stdout != "" ->
        output = String.slice(stdout, 0, 1000)

        send_reply(state.client, state.chat_id, "Output:\n```\n#{output}\n```",
          parse_mode: "Markdown"
        )

      {:ok, %{"ok" => false, "stderr" => stderr}} when stderr != "" ->
        output = String.slice(stderr, 0, 1000)

        send_reply(state.client, state.chat_id, "Error:\n```\n#{output}\n```",
          parse_mode: "Markdown"
        )

      _ ->
        :ok
    end
  end

  defp handle_agent_event({:error, msg}, state) do
    send_reply(state.client, state.chat_id, "Error: #{msg}")
  end

  defp handle_agent_event({:status, :thinking}, state) do
    send_chat_action(state.client, state.chat_id, "typing")
  end

  defp handle_agent_event(_event, _state), do: :ok

  defp new_session(user_id) do
    Session.new(nil,
      screen_type: :chat,
      session_id: "tg-#{user_id}-#{System.system_time(:second)}"
    )
  end

  defp send_reply(client, chat_id, text, opts \\ []) do
    truncated = String.slice(text, 0, @max_message_chars)

    case Nadia.send_message(client, chat_id, truncated, opts) do
      {:ok, _} -> :ok
      {:error, error} -> Beamcore.AppLog.warn("Telegram send failed: #{inspect(error)}")
    end
  end

  defp send_chat_action(client, chat_id, action) do
    Nadia.send_chat_action(client, chat_id, action)
  end
end
