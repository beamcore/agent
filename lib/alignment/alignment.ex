defmodule Beamcore.Alignment do
  @moduledoc """
  Deterministic agent coordination server. Tracks active file claims to prevent
  duplicate or conflicting work across multiple agents.
  """
  use GenServer
  require Logger

  # Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Attempts to claim a file for an agent. If a conflict is detected, returns a score and the conflicting agent.
  """
  def claim_file(path, agent_name, file_hash) do
    GenServer.call(__MODULE__, {:claim, path, agent_name, file_hash})
  end

  @doc """
  Releases a file claim for an agent.
  """
  def release_file(path, agent_name) do
    GenServer.cast(__MODULE__, {:release, path, agent_name})
  end

  @doc """
  Lists all active file claims.
  """
  def list_claims do
    GenServer.call(__MODULE__, :list_claims)
  end

  @doc """
  Clears all active claims.
  """
  def clear_claims do
    GenServer.cast(__MODULE__, :clear_claims)
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    # State: %{path => %{agent: agent_name, hash: file_hash, timestamp: DateTime.t()}}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:claim, path, agent_name, file_hash}, _from, state) do
    now = DateTime.utc_now()
    
    case Map.get(state, path) do
      nil ->
        new_state = Map.put(state, path, %{agent: agent_name, hash: file_hash, timestamp: now})
        {:reply, {:ok, :claimed}, new_state}

      %{agent: ^agent_name} = claim ->
        new_state = Map.put(state, path, %{claim | hash: file_hash, timestamp: now})
        {:reply, {:ok, :already_claimed}, new_state}

      %{agent: other_agent, hash: other_hash, timestamp: other_time} ->
        time_diff_secs = DateTime.diff(now, other_time, :second)
        
        base_score = 50
        hash_score = if file_hash == other_hash, do: 30, else: 0
        
        recency_score =
          cond do
            time_diff_secs <= 300 -> 20
            time_diff_secs <= 900 -> 10
            true -> 0
          end
          
        score = base_score + hash_score + recency_score
        
        new_state = Map.put(state, path, %{agent: agent_name, hash: file_hash, timestamp: now})
        {:reply, {:conflict, score, other_agent}, new_state}
    end
  end

  @impl true
  def handle_call(:list_claims, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:release, path, agent_name}, state) do
    case Map.get(state, path) do
      %{agent: ^agent_name} ->
        {:noreply, Map.delete(state, path)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:clear_claims, _state) do
    {:noreply, %{}}
  end
end
