defmodule Beamcore.Memory do
  @moduledoc """
  Memory service manages persistent knowledge for AI agents.
  Entries are scoped hierarchically by organization, repository, and category.
  Uses ETS for fast in-memory concurrent reads and DETS for file-backed persistence.
  """

  use GenServer

  @default_dets_path "~/.beamcore/memory.dets"

  # --- Client API ---

  @doc """
  Starts the Memory GenServer.

  Supported options:
    - `:global` (boolean) - if true, registers the process globally as `{:global, Beamcore.Memory}`
    - `:dets_path` (string) - custom DETS file path
  """
  def start_link(opts \\ []) do
    name =
      if opts[:global] || System.get_env("MEMORY_GLOBAL") == "true" do
        {:global, __MODULE__}
      else
        __MODULE__
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Saves a memory entry. Scopes it by category/type, org, repo, and key.
  """
  def remember(org, repo, type, key, value) do
    case server_ref() do
      nil ->
        fallback_remember(org, repo, type, key, value)

      ref ->
        GenServer.call(ref, {:remember, org, repo, type, key, value})
    end
  end

  @doc """
  Retrieves a specific memory entry.
  """
  def recall(org, repo, type, key) do
    case server_ref() do
      nil ->
        fallback_recall(org, repo, type, key)

      ref ->
        GenServer.call(ref, {:recall, org, repo, type, key})
    end
  end

  @doc """
  Deletes a specific memory entry.
  """
  def forget(org, repo, type, key) do
    case server_ref() do
      nil ->
        fallback_forget(org, repo, type, key)

      ref ->
        GenServer.call(ref, {:forget, org, repo, type, key})
    end
  end

  @doc """
  Lists all memory entries for a specific category under the org and repo.
  """
  def list(org, repo, type) do
    case server_ref() do
      nil ->
        fallback_list(org, repo, type)

      ref ->
        GenServer.call(ref, {:list, org, repo, type})
    end
  end

  @doc """
  Clears all memory entries from ETS and DETS.
  """
  def clear do
    case server_ref() do
      nil ->
        fallback_clear()

      ref ->
        GenServer.call(ref, :clear)
    end
  end

  @doc """
  Detects the organization and repository name dynamically.
  """
  def detect_org_repo do
    # Reuses the robust Git/Environment detection logic from Ledger
    env_org = System.get_env("BEAMCORE_ORG")
    env_repo = System.get_env("BEAMCORE_REPO")

    if env_org && env_repo do
      {env_org, env_repo}
    else
      case System.cmd("git", ["config", "--get", "remote.origin.url"]) do
        {url, 0} ->
          url = String.trim(url)

          case parse_git_url(url) do
            {org, repo} -> {org, repo}
            nil -> {"default_org", "default_repo"}
          end

        _ ->
          {"default_org", "default_repo"}
      end
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    dets_path =
      opts[:dets_path] ||
        Application.get_env(:agent, :memory_dets_path) ||
        System.get_env("MEMORY_DETS_PATH") ||
        @default_dets_path

    expanded_path = Path.expand(dets_path)

    # Ensure parent directory exists
    File.mkdir_p!(Path.dirname(expanded_path))

    dets_name = opts[:dets_name] || :beamcore_memory_store
    ets_name = opts[:ets_name] || :beamcore_memory_store

    # Initialize public ETS table
    if :ets.info(ets_name) == :undefined do
      :ets.new(ets_name, [:set, :public, :named_table])
    end

    # Open DETS table
    dets_ref =
      case :dets.open_file(dets_name, file: to_charlist(expanded_path)) do
        {:ok, table} ->
          table

        {:error, reason} ->
          case reason do
            {:already_open, pid} -> pid
            _ -> raise "Could not open DETS memory store: #{inspect(reason)}"
          end
      end

    # Replicate DETS data into ETS for fast, concurrent O(1) in-memory reads
    case :dets.to_ets(dets_name, ets_name) do
      {:error, reason} -> raise "Could not load DETS data into ETS: #{inspect(reason)}"
      _ -> :ok
    end

    state = %{
      dets_path: dets_path,
      expanded_path: expanded_path,
      dets_ref: dets_ref,
      dets_name: dets_name,
      ets_name: ets_name
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.dets_name)
    :ok
  end

  @impl true
  def handle_call({:remember, org, repo, type, key, value}, _from, state) do
    state = ensure_runtime_tables(state)
    entry_key = {type, org, repo, key}

    # 1. Update ETS
    :ets.insert(state.ets_name, {entry_key, value})

    # 2. Update DETS
    :dets.insert(state.dets_name, {entry_key, value})
    :dets.sync(state.dets_name)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:recall, org, repo, type, key}, _from, state) do
    state = ensure_runtime_tables(state)
    entry_key = {type, org, repo, key}

    result =
      case :ets.lookup(state.ets_name, entry_key) do
        [{^entry_key, value}] -> value
        _ -> nil
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:forget, org, repo, type, key}, _from, state) do
    state = ensure_runtime_tables(state)
    entry_key = {type, org, repo, key}

    # 1. Delete from ETS
    :ets.delete(state.ets_name, entry_key)

    # 2. Delete from DETS
    :dets.delete(state.dets_name, entry_key)
    :dets.sync(state.dets_name)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list, org, repo, type}, _from, state) do
    state = ensure_runtime_tables(state)
    # Select memories of matching category, org, and repo
    match_spec = [{{{type, org, repo, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]
    results = :ets.select(state.ets_name, match_spec)

    {:reply, results, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    state = ensure_runtime_tables(state)
    # Delete all items
    :ets.delete_all_objects(state.ets_name)
    :dets.delete_all_objects(state.dets_name)
    :dets.sync(state.dets_name)

    {:reply, :ok, state}
  end

  # --- Helper functions ---

  defp ensure_runtime_tables(state) do
    ensure_ets_table(state.ets_name)
    ensure_dets_table(state)
  end

  defp ensure_ets_table(ets_name) do
    if :ets.info(ets_name) == :undefined do
      :ets.new(ets_name, [:set, :public, :named_table])
    end

    :ok
  end

  defp ensure_dets_table(state) do
    case :dets.info(state.dets_name) do
      :undefined ->
        case :dets.open_file(state.dets_name, file: to_charlist(state.expanded_path)) do
          {:ok, _table} ->
            case :dets.to_ets(state.dets_name, state.ets_name) do
              {:error, reason} -> raise "Could not reload DETS data into ETS: #{inspect(reason)}"
              _ -> state
            end

          {:error, {:already_open, _pid}} ->
            state

          {:error, reason} ->
            raise "Could not reopen DETS memory store: #{inspect(reason)}"
        end

      _info ->
        state
    end
  end

  defp server_ref do
    cond do
      GenServer.whereis({:global, __MODULE__}) -> {:global, __MODULE__}
      GenServer.whereis(__MODULE__) -> __MODULE__
      true -> nil
    end
  end

  # --- Fallback implementations for robust direct usage when GenServer isn't running ---

  defp fallback_remember(org, repo, type, key, value) do
    ensure_fallback_initialized()
    entry_key = {type, org, repo, key}

    if :ets.info(:beamcore_memory_store) != :undefined do
      :ets.insert(:beamcore_memory_store, {entry_key, value})
    end

    try do
      :dets.insert(:beamcore_memory_store, {entry_key, value})
      :dets.sync(:beamcore_memory_store)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp fallback_recall(org, repo, type, key) do
    ensure_fallback_initialized()
    entry_key = {type, org, repo, key}

    if :ets.info(:beamcore_memory_store) != :undefined do
      case :ets.lookup(:beamcore_memory_store, entry_key) do
        [{^entry_key, value}] -> value
        _ -> nil
      end
    else
      nil
    end
  end

  defp fallback_forget(org, repo, type, key) do
    ensure_fallback_initialized()
    entry_key = {type, org, repo, key}

    if :ets.info(:beamcore_memory_store) != :undefined do
      :ets.delete(:beamcore_memory_store, entry_key)
    end

    try do
      :dets.delete(:beamcore_memory_store, entry_key)
      :dets.sync(:beamcore_memory_store)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp fallback_list(org, repo, type) do
    ensure_fallback_initialized()

    if :ets.info(:beamcore_memory_store) != :undefined do
      match_spec = [{{{type, org, repo, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]
      :ets.select(:beamcore_memory_store, match_spec)
    else
      []
    end
  end

  defp fallback_clear do
    ensure_fallback_initialized()

    if :ets.info(:beamcore_memory_store) != :undefined do
      :ets.delete_all_objects(:beamcore_memory_store)
    end

    try do
      :dets.delete_all_objects(:beamcore_memory_store)
      :dets.sync(:beamcore_memory_store)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp ensure_fallback_initialized do
    if :ets.info(:beamcore_memory_store) == :undefined do
      :ets.new(:beamcore_memory_store, [:set, :public, :named_table])
    end

    dets_path =
      Application.get_env(:agent, :memory_dets_path) ||
        System.get_env("MEMORY_DETS_PATH") ||
        @default_dets_path

    expanded_path = Path.expand(dets_path)

    try do
      File.mkdir_p!(Path.dirname(expanded_path))
      :dets.open_file(:beamcore_memory_store, file: to_charlist(expanded_path))
      :dets.to_ets(:beamcore_memory_store, :beamcore_memory_store)
    rescue
      _ -> :ok
    end
  end

  defp parse_git_url(url) do
    url = String.replace_suffix(url, ".git", "")
    parts = String.split(url, [":", "/"])

    case Enum.reverse(parts) do
      [repo, org | _] -> {org, repo}
      _ -> nil
    end
  end
end
