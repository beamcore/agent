defmodule Beamcore.Agent.FilesystemJournal.Server do
  @moduledoc """
  OTP owner for filesystem journal transactions.

  The server serializes journal appends and restore application per workspace.
  It intentionally keeps a small API so the existing journal implementation
  remains the source of truth for provenance and selective rollback semantics.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def transaction(workspace_root, fun, timeout \\ :infinity)
      when is_binary(workspace_root) and is_function(fun, 0) do
    if Process.get(:beamcore_filesystem_journal_owner?) == true or
         is_nil(Process.whereis(__MODULE__)) do
      fun.()
    else
      GenServer.call(__MODULE__, {:transaction, workspace_root, fun}, timeout)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{queues: %{}, active: MapSet.new()}}

  @impl true
  def handle_call({:transaction, workspace_root, fun}, from, state) do
    if MapSet.member?(state.active, workspace_root) do
      queue = Map.get(state.queues, workspace_root, [])
      {:noreply, %{state | queues: Map.put(state.queues, workspace_root, queue ++ [{from, fun}])}}
    else
      result = run_owned(fun)

      {:reply, result,
       run_next(%{state | active: MapSet.delete(state.active, workspace_root)}, workspace_root)}
    end
  end

  defp run_next(state, workspace_root) do
    case Map.get(state.queues, workspace_root, []) do
      [] ->
        %{state | queues: Map.delete(state.queues, workspace_root)}

      [{from, fun} | rest] ->
        GenServer.reply(from, run_owned(fun))
        run_next(%{state | queues: Map.put(state.queues, workspace_root, rest)}, workspace_root)
    end
  end

  defp run_owned(fun) do
    previous = Process.get(:beamcore_filesystem_journal_owner?)
    Process.put(:beamcore_filesystem_journal_owner?, true)

    try do
      fun.()
    after
      if previous do
        Process.put(:beamcore_filesystem_journal_owner?, previous)
      else
        Process.delete(:beamcore_filesystem_journal_owner?)
      end
    end
  end
end
