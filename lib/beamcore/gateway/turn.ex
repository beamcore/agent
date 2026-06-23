defmodule Beamcore.Gateway.Turn do
  @moduledoc """
  Shared agent turn lifecycle and event dispatch for all adapters.

  Handles: starting turns, queue processing, canceling, task result handling,
  and formatting gateway events into platform-agnostic response tuples.
  """

  alias Beamcore.Agent.Chat.Loop
  alias Beamcore.Gateway.SessionStore

  @type send_fn :: (binary(), binary(), keyword() -> :ok)
  @type typing_fn :: (-> :ok)

  @doc """
  Start an agent turn or queue the message if busy.
  """
  def dispatch(chat_key, platform, text, _send_fn, typing_fn) do
    case SessionStore.get_or_create(chat_key, platform) do
      {:ok, %{task_ref: ref}} when ref != nil ->
        SessionStore.queue_message(chat_key, text)
        typing_fn.()

      {:ok, session_state} ->
        start_turn(session_state, text, typing_fn)
    end
  end

  @doc """
  Start the agent task for a session.
  """
  def start_turn(session_state, text, typing_fn) do
    chat_key = session_state.chat_key
    typing_fn.()
    parent = self()

    task =
      Task.Supervisor.async_nolink(Beamcore.Agent.TaskSupervisor, fn ->
        Loop.send_message(session_state.session, text, nil,
          event_handler: fn event ->
            send(parent, {:gateway_event, chat_key, event})
          end
        )
      end)

    SessionStore.put(chat_key, %{session_state | task_ref: task.ref})
  end

  @doc """
  Process the queued message after a turn completes.
  """
  def process_queue(chat_key, typing_fn) do
    case SessionStore.dequeue_message(chat_key) do
      {:ok, text} ->
        case SessionStore.get(chat_key) do
          {:ok, session_state} -> start_turn(session_state, text, typing_fn)
          :not_found -> :ok
        end

      :empty ->
        :ok
    end
  end

  @doc """
  Cancel the running turn for a chat.
  """
  def cancel(chat_key) do
    case SessionStore.get(chat_key) do
      {:ok, %{task_ref: ref} = session_state} when ref != nil ->
        Process.exit(ref, :kill)
        SessionStore.put(chat_key, %{session_state | task_ref: nil})
        :ok

      _ ->
        :not_running
    end
  end

  @doc """
  Handle a task completion. Returns `{:ok, chat_key}` or `:not_found`.
  """
  def handle_result(ref, session) do
    case find_chat_by_ref(ref) do
      {:ok, chat_key} ->
        case SessionStore.get(chat_key) do
          {:ok, session_state} ->
            SessionStore.put(chat_key, %{session_state | session: session, task_ref: nil})

          :not_found ->
            :ok
        end

        {:ok, chat_key}

      :not_found ->
        :not_found
    end
  end

  @doc """
  Handle a task failure. Returns `{:ok, chat_key}` or `:not_found`.
  """
  def handle_failure(ref, reason) do
    case find_chat_by_ref(ref) do
      {:ok, chat_key} ->
        case SessionStore.get(chat_key) do
          {:ok, session_state} ->
            SessionStore.put(chat_key, %{session_state | task_ref: nil})

          :not_found ->
            :ok
        end

        {:ok, chat_key, reason}

      :not_found ->
        :not_found
    end
  end

  @doc """
  Format a gateway event into a response tuple.

  Returns:
  - `{:text, content}` — send as message
  - `{:code, code}` — send as code block
  - `{:error, msg}` — send as error
  - `:typing` — send typing indicator
  - `:ignore` — do nothing
  """
  def format_event({:assistant, content}) when is_binary(content) and content != "",
    do: {:text, content}

  def format_event({:eeva_preview, code}) when is_binary(code),
    do: {:code, String.slice(code, 0, 300)}

  def format_event({:tool_running, "eeva", %{code: code}}),
    do: {:code, String.slice(code, 0, 300)}

  def format_event({:tool_finished, "eeva", _, result_json}) do
    case Jason.decode(result_json) do
      {:ok, %{"ok" => true, "stdout" => stdout}}
      when is_binary(stdout) and stdout != "" and stdout != "\n" ->
        {:code, String.slice(stdout, 0, 1000)}

      {:ok, %{"ok" => false, "stderr" => stderr}} when is_binary(stderr) and stderr != "" ->
        {:error_code, String.slice(stderr, 0, 1000)}

      _ ->
        :ignore
    end
  end

  def format_event({:status, :thinking}), do: :typing
  def format_event({:error, msg}), do: {:error, msg}
  def format_event(_), do: :ignore

  # -- Internal ----------------------------------------------------------------

  defp find_chat_by_ref(ref) do
    :ets.foldl(
      fn {chat_key, %{task_ref: task_ref}}, acc ->
        if task_ref == ref, do: {:ok, chat_key}, else: acc
      end,
      :not_found,
      :gateway_sessions
    )
  end
end
