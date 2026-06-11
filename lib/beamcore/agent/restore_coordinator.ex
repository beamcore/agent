defmodule Beamcore.Agent.RestoreCoordinator do
  @moduledoc """
  Supervised coordinator for filesystem restore operations.

  A coordinator owns one restore request, delegates the actual selective
  rollback to `Beamcore.Agent.FilesystemJournal`, and exits after replying to
  the caller. The journal server serializes workspace mutation/restore access.
  """

  use GenServer

  alias Beamcore.Agent.FilesystemJournal
  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Timeline

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def restore(session, checkpoint) do
    case Process.whereis(Beamcore.Agent.RestoreSupervisor) do
      nil ->
        FilesystemJournal.restore_to_checkpoint_owned(session, checkpoint)

      _pid ->
        with {:ok, pid} <-
               DynamicSupervisor.start_child(
                 Beamcore.Agent.RestoreSupervisor,
                 {__MODULE__, []}
               ) do
          try do
            GenServer.call(pid, {:restore, session, checkpoint}, :infinity)
          after
            DynamicSupervisor.terminate_child(Beamcore.Agent.RestoreSupervisor, pid)
          end
        end
    end
  end

  def restore_async(session, checkpoint_id, action, caller)
      when action in [:rewind, :fork] and is_pid(caller) do
    with checkpoint when not is_nil(checkpoint) <-
           Timeline.find_checkpoint(session, checkpoint_id),
         {:ok, pid} <- start_restore_child() do
      restore_id = FilesystemJournal.restore_id()
      GenServer.cast(pid, {:restore_async, restore_id, session, checkpoint, action, caller})
      {:accepted, restore_id}
    else
      nil -> {:error, "Checkpoint '#{checkpoint_id}' was not found."}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:restore, session, checkpoint}, _from, state) do
    {:reply, FilesystemJournal.restore_to_checkpoint_owned(session, checkpoint), state}
  end

  @impl true
  def handle_cast({:restore_async, restore_id, session, checkpoint, action, caller}, state) do
    progress = fn event ->
      send(caller, {:restore_progress, restore_id, Map.put(event, :action, action)})
    end

    progress.(%{
      phase: "requested",
      status: "started",
      session_id: session.session_id,
      branch_id: session.branch_id,
      checkpoint_id: checkpoint.id,
      restore_id: restore_id,
      summary: "Restore requested"
    })

    restore_result =
      with {:ok, filesystem_result} <-
             FilesystemJournal.restore_to_checkpoint_owned(session, checkpoint,
               restore_id: restore_id,
               progress: progress
             ),
           {:ok, restored_session} <- apply_timeline_action(session, checkpoint.id, action) do
        restored_session =
          restored_session
          |> Session.annotate_filesystem_restore(filesystem_result)
          |> Session.save_state()

        {:ok, restored_session, filesystem_result}
      end

    result =
      case restore_result do
        {:ok, _restored_session, _filesystem_result} = ok -> ok
        {:error, reason} -> {:error, session.session_id, reason}
      end

    send(caller, {:restore_completed, restore_id, action, checkpoint.id, result})
    {:stop, :normal, state}
  end

  defp start_restore_child do
    case Process.whereis(Beamcore.Agent.RestoreSupervisor) do
      nil ->
        start_link([])

      _pid ->
        DynamicSupervisor.start_child(Beamcore.Agent.RestoreSupervisor, {__MODULE__, []})
    end
  end

  defp apply_timeline_action(session, checkpoint_id, :rewind),
    do: Timeline.rewind(session, checkpoint_id)

  defp apply_timeline_action(session, checkpoint_id, :fork),
    do: Timeline.fork(session, checkpoint_id)
end
