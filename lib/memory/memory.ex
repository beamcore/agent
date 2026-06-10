defmodule Beamcore.Memory do
  @moduledoc """
  Persistent project memory for AI agents.

  Memory is intentionally outside filesystem snapshots/checkpoints. The model may
  read and write memories through this module, while checkpoint/timeline/restore
  remain runtime-only mechanisms.

  Model-friendly calls:

      Beamcore.Memory.remember("project_description", "...")
      Beamcore.Memory.remember(:facts, "project_description", "...")
      Beamcore.Memory.recall("project_description")
      Beamcore.Memory.recall(:facts, "project_description")
      Beamcore.Memory.search("snapshot")
      Beamcore.Memory.overview()

  Large limits are clamped automatically so a model cannot get stuck increasing
  limits forever.
  """

  use GenServer

  @default_dets_path "~/.beamcore/memory.dets"
  @max_key_bytes 512
  @max_value_bytes 64 * 1024
  @default_type :facts
  @default_limit 20
  @max_limit 50
  @known_types MapSet.new([
                 :facts,
                 :fact,
                 :decisions,
                 :decision,
                 :patterns,
                 :pattern,
                 :errors,
                 :error,
                 :context,
                 :contexts,
                 :notes,
                 :note,
                 :preferences,
                 :preference,
                 :research,
                 :tasks,
                 :task,
                 :project,
                 :projects
               ])

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
  Saves a memory entry under the default `:facts` type.

  This is the safest model-facing form when the model simply needs to remember
  something by key.
  """
  def remember(key, value), do: remember(@default_type, key, value)

  @doc """
  Saves a memory entry.

  Preferred forms:

      remember(:facts, "key", "value")
      remember("key", "value")

  The 3-argument form is intentionally tolerant of a common model mistake:
  `remember(:some_key, "value", 1_000_000)` is treated as
  `remember(:facts, "some_key", "value")` because the third argument looks like
  an accidental search/list limit rather than a useful memory value.
  """
  def remember(type, key, value) do
    {type, key, value} = normalize_remember3(type, key, value)
    {org, repo} = detect_org_repo()
    remember(org, repo, type, key, value)
  end

  def remember(org, repo, type, key, value) do
    type = normalize_type(type)
    key = normalize_key(key)

    with :ok <- validate_memory_entry(type, key, value) do
      remember_validated(org, repo, type, key, value)
    end
  end

  @doc """
  Recalls a memory by key across all types in the current project scope.

  Returns the value for a single match, a compact list of matches for multiple
  matches, or `nil` when nothing matches.
  """
  def recall(key) do
    {org, repo} = detect_org_repo()
    smart_recall(org, repo, key, @default_limit)
  end

  @doc """
  Recalls a specific typed memory.

  `recall(type, key)` performs an exact lookup. If the second argument is a
  number, it is treated as an accidental limit and the first argument is used as
  a broad search key. This prevents model loops like repeatedly calling
  `recall(:project_description, 1_000_000)`.
  """
  def recall(type, key_or_limit) when is_integer(key_or_limit) do
    {org, repo} = detect_org_repo()
    smart_recall(org, repo, type, key_or_limit)
  end

  def recall(type, key) do
    {org, repo} = detect_org_repo()
    recall(org, repo, type, key)
  end

  def recall(type, key, limit) when is_integer(limit) do
    case recall(type, key) do
      nil -> search(type, key, limit)
      value -> value
    end
  end

  def recall(org, repo, type, key) do
    type = normalize_type(type)
    key = normalize_key(key)

    case server_ref() do
      nil ->
        fallback_recall(org, repo, type, key)

      ref ->
        GenServer.call(ref, {:recall, org, repo, type, key})
    end
  end

  @doc """
  Deletes memory entries from the current project scope.

  `forget(key)` deletes all entries with that key across types.
  `forget(type, key)` deletes one typed entry.
  """
  def forget(key) do
    {org, repo} = detect_org_repo()
    key = normalize_key(key)

    all_current_entries(org, repo)
    |> Enum.filter(&(&1.key == key))
    |> Enum.each(fn entry -> forget(org, repo, entry.type, entry.key) end)

    :ok
  end

  def forget(type, key) do
    {org, repo} = detect_org_repo()
    forget(org, repo, type, key)
  end

  def forget(org, repo, type, key) do
    type = normalize_type(type)
    key = normalize_key(key)

    case server_ref() do
      nil ->
        fallback_forget(org, repo, type, key)

      ref ->
        GenServer.call(ref, {:forget, org, repo, type, key})
    end
  end

  @doc """
  Lists a compact overview of all memory types in the current project scope.
  """
  def list do
    overview()
  end

  @doc """
  Lists memories for a type with an automatic safe limit.
  """
  def list(type), do: list(type, @default_limit)

  def list(type, limit) when is_integer(limit) do
    {org, repo} = detect_org_repo()
    list(org, repo, type, clamp_limit(limit))
  end

  def list(org, repo, type), do: list(org, repo, type, :all)

  def list(org, repo, type, limit) do
    type = normalize_type(type)

    case server_ref() do
      nil ->
        fallback_list(org, repo, type, limit)

      ref ->
        GenServer.call(ref, {:list, org, repo, type, limit})
    end
  end

  @doc """
  Searches memory keys, types, and inspectable values in the current project.

  The limit is always clamped to a small maximum, even if the model asks for an
  absurdly large number.
  """
  def search(query), do: search(query, @default_limit)

  def search(query, limit) when is_integer(limit) do
    {org, repo} = detect_org_repo()
    search(org, repo, nil, query, clamp_limit(limit))
  end

  def search(type, query) do
    {org, repo} = detect_org_repo()
    search(org, repo, normalize_type(type), query, @default_limit)
  end

  def search(type, query, limit) when is_integer(limit) do
    {org, repo} = detect_org_repo()
    search(org, repo, normalize_type(type), query, clamp_limit(limit))
  end

  @doc """
  Returns the known memory types and counts for the current project scope.
  """
  def types do
    {org, repo} = detect_org_repo()

    case server_ref() do
      nil -> fallback_types(org, repo)
      ref -> GenServer.call(ref, {:types, org, repo})
    end
  end

  @doc """
  Returns a compact memory overview for the current project scope.
  """
  def overview do
    {org, repo} = detect_org_repo()

    case server_ref() do
      nil -> fallback_overview(org, repo)
      ref -> GenServer.call(ref, {:overview, org, repo})
    end
  end

  def summary, do: overview()

  @doc """
  Clears all memory entries from ETS and DETS.

  This remains model-facing so an explicit user request such as "forget
  everything" can be honored.
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
    root =
      Process.get(:workspace_root) ||
        Application.get_env(:agent, :workspace_root) ||
        File.cwd!()

    detect_org_repo(root)
  end

  def detect_org_repo(workspace_root) when is_binary(workspace_root) do
    env_org = System.get_env("BEAMCORE_ORG")
    env_repo = System.get_env("BEAMCORE_REPO")

    if env_org && env_repo do
      {env_org, env_repo}
    else
      git_root = Path.expand(workspace_root)

      case System.cmd("git", ["-C", git_root, "config", "--get", "remote.origin.url"]) do
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
    File.mkdir_p!(Path.dirname(expanded_path))

    dets_name = opts[:dets_name] || :beamcore_memory_store
    ets_name = opts[:ets_name] || :beamcore_memory_store

    if :ets.info(ets_name) == :undefined do
      :ets.new(ets_name, [:set, :public, :named_table])
    end

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

    current = lookup_value(state.ets_name, entry_key, :__beamcore_memory_missing__)

    reply =
      if current == value do
        :ok
      else
        with true <- :ets.insert(state.ets_name, {entry_key, value}),
             :ok <- :dets.insert(state.dets_name, {entry_key, value}),
             :ok <- :dets.sync(state.dets_name) do
          :ok
        else
          false -> {:error, :ets_insert_failed}
          {:error, reason} -> {:error, reason}
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:recall, org, repo, type, key}, _from, state) do
    state = ensure_runtime_tables(state)
    entry_key = {type, org, repo, key}
    {:reply, lookup_value(state.ets_name, entry_key, nil), state}
  end

  @impl true
  def handle_call({:forget, org, repo, type, key}, _from, state) do
    state = ensure_runtime_tables(state)
    entry_key = {type, org, repo, key}

    :ets.delete(state.ets_name, entry_key)

    reply =
      with :ok <- :dets.delete(state.dets_name, entry_key),
           :ok <- :dets.sync(state.dets_name) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:list, org, repo, type, limit}, _from, state) do
    state = ensure_runtime_tables(state)
    entries = entries_for(state.ets_name, org, repo, type: type)
    {:reply, entries_to_pairs(entries, limit), state}
  end

  @impl true
  def handle_call({:entries, org, repo}, _from, state) do
    state = ensure_runtime_tables(state)
    {:reply, entries_for(state.ets_name, org, repo), state}
  end

  @impl true
  def handle_call({:types, org, repo}, _from, state) do
    state = ensure_runtime_tables(state)
    {:reply, types_from_entries(entries_for(state.ets_name, org, repo)), state}
  end

  @impl true
  def handle_call({:overview, org, repo}, _from, state) do
    state = ensure_runtime_tables(state)
    {:reply, overview_from_entries(entries_for(state.ets_name, org, repo), org, repo), state}
  end

  @impl true
  def handle_call({:search, org, repo, type_filter, query, limit}, _from, state) do
    state = ensure_runtime_tables(state)

    result =
      state.ets_name
      |> entries_for(org, repo, type: type_filter)
      |> search_entries(query, limit)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    state = ensure_runtime_tables(state)
    :ets.delete_all_objects(state.ets_name)

    reply =
      with :ok <- :dets.delete_all_objects(state.dets_name),
           :ok <- :dets.sync(state.dets_name) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  # --- Search/overview helpers ---

  defp search(org, repo, type_filter, query, limit) do
    limit = clamp_limit(limit)

    case server_ref() do
      nil -> fallback_search(org, repo, type_filter, query, limit)
      ref -> GenServer.call(ref, {:search, org, repo, type_filter, query, limit})
    end
  end

  defp smart_recall(org, repo, query, requested_limit) do
    limit = clamp_limit(requested_limit)
    exact_key = normalize_key(query)

    matches =
      all_current_entries(org, repo)
      |> Enum.filter(fn entry -> entry.key == exact_key end)
      |> Enum.take(limit)

    matches = if matches == [], do: search(org, repo, nil, query, limit), else: entries_to_model_maps(matches)

    case matches do
      [] -> nil
      [%{value: value}] -> value
      many -> many
    end
  end

  defp all_current_entries(org, repo) do
    case server_ref() do
      nil -> fallback_entries(org, repo)
      ref -> GenServer.call(ref, {:entries, org, repo})
    end
  end

  defp remember_validated(org, repo, type, key, value) do
    case server_ref() do
      nil ->
        fallback_remember(org, repo, type, key, value)

      ref ->
        GenServer.call(ref, {:remember, org, repo, type, key, value})
    end
  end

  defp search_entries(entries, query, limit) do
    query_text = query_to_text(query)

    entries
    |> Enum.filter(fn entry -> query_text == "" or memory_entry_matches?(entry, query_text) end)
    |> Enum.take(clamp_limit(limit))
    |> entries_to_model_maps()
  end

  defp memory_entry_matches?(entry, query_text) do
    haystack =
      [entry.type, entry.key, inspect(entry.value, limit: 20, printable_limit: 1_000)]
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.join("\n")

    String.contains?(haystack, query_text)
  end

  defp entries_to_model_maps(entries) do
    Enum.map(entries, fn entry ->
      %{
        type: entry.type,
        key: entry.key,
        value: compact_value(entry.value)
      }
    end)
  end

  defp entries_to_pairs(entries, :all), do: Enum.map(entries, &{&1.key, compact_value(&1.value)})

  defp entries_to_pairs(entries, limit),
    do: entries |> Enum.take(clamp_limit(limit)) |> Enum.map(&{&1.key, compact_value(&1.value)})

  defp types_from_entries(entries) do
    entries
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {type, typed_entries} ->
      %{type: type, count: length(typed_entries), sample_keys: typed_entries |> Enum.map(& &1.key) |> Enum.take(5)}
    end)
    |> Enum.sort_by(&to_string(&1.type))
  end

  defp overview_from_entries(entries, org, repo) do
    %{
      org: org,
      repo: repo,
      total: length(entries),
      types: types_from_entries(entries)
    }
  end

  defp entries_for(ets_name, org, repo, opts \\ []) do
    type_filter = Keyword.get(opts, :type)

    if :ets.info(ets_name) == :undefined do
      []
    else
      ets_name
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{type, ^org, ^repo, key}, value} ->
          if is_nil(type_filter) or type == type_filter do
            [%{type: type, key: key, value: value}]
          else
            []
          end

        _ ->
          []
      end)
      |> Enum.sort_by(fn entry -> {to_string(entry.type), to_string(entry.key)} end)
    end
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

    current =
      if :ets.info(:beamcore_memory_store) != :undefined do
        lookup_value(:beamcore_memory_store, entry_key, :__beamcore_memory_missing__)
      else
        :__beamcore_memory_missing__
      end

    if current == value do
      :ok
    else
      if :ets.info(:beamcore_memory_store) != :undefined do
        :ets.insert(:beamcore_memory_store, {entry_key, value})
      end

      sync_fallback_dets(fn -> :dets.insert(:beamcore_memory_store, {entry_key, value}) end)
    end
  end

  defp fallback_recall(org, repo, type, key) do
    ensure_fallback_initialized()
    entry_key = {type, org, repo, key}

    if :ets.info(:beamcore_memory_store) != :undefined do
      lookup_value(:beamcore_memory_store, entry_key, nil)
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

    sync_fallback_dets(fn -> :dets.delete(:beamcore_memory_store, entry_key) end)
  end

  defp fallback_list(org, repo, type, limit) do
    ensure_fallback_initialized()

    :beamcore_memory_store
    |> entries_for(org, repo, type: type)
    |> entries_to_pairs(limit)
  end

  defp fallback_search(org, repo, type_filter, query, limit) do
    ensure_fallback_initialized()

    :beamcore_memory_store
    |> entries_for(org, repo, type: type_filter)
    |> search_entries(query, limit)
  end

  defp fallback_types(org, repo) do
    ensure_fallback_initialized()
    :beamcore_memory_store |> entries_for(org, repo) |> types_from_entries()
  end

  defp fallback_overview(org, repo) do
    ensure_fallback_initialized()
    :beamcore_memory_store |> entries_for(org, repo) |> overview_from_entries(org, repo)
  end

  defp fallback_entries(org, repo) do
    ensure_fallback_initialized()
    entries_for(:beamcore_memory_store, org, repo)
  end

  defp fallback_clear do
    ensure_fallback_initialized()

    if :ets.info(:beamcore_memory_store) != :undefined do
      :ets.delete_all_objects(:beamcore_memory_store)
    end

    sync_fallback_dets(fn -> :dets.delete_all_objects(:beamcore_memory_store) end)
  end

  defp sync_fallback_dets(operation) when is_function(operation, 0) do
    try do
      case operation.() do
        :ok -> :dets.sync(:beamcore_memory_store)
        {:error, reason} -> {:error, reason}
        other -> other
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
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

  defp lookup_value(ets_name, entry_key, default) do
    case :ets.lookup(ets_name, entry_key) do
      [{^entry_key, value}] -> value
      _ -> default
    end
  end

  defp normalize_remember3(type, key, value) do
    if probable_accidental_limit?(value) and not known_type?(type) and storable_memory_value?(key) do
      {@default_type, normalize_key(type), key}
    else
      {type, key, value}
    end
  end

  defp known_type?(value), do: MapSet.member?(@known_types, normalize_type(value))

  defp normalize_type(value) when is_atom(value), do: canonical_type(value)
  defp normalize_type(value) when is_binary(value), do: canonical_type(String.trim(value))
  defp normalize_type(value), do: value

  defp canonical_type(:fact), do: :facts
  defp canonical_type(:decision), do: :decisions
  defp canonical_type(:pattern), do: :patterns
  defp canonical_type(:error), do: :errors
  defp canonical_type(:contexts), do: :context
  defp canonical_type(:note), do: :notes
  defp canonical_type(:preference), do: :preferences
  defp canonical_type(:task), do: :tasks
  defp canonical_type(:project), do: :projects
  defp canonical_type("fact"), do: :facts
  defp canonical_type("facts"), do: :facts
  defp canonical_type("decision"), do: :decisions
  defp canonical_type("decisions"), do: :decisions
  defp canonical_type("pattern"), do: :patterns
  defp canonical_type("patterns"), do: :patterns
  defp canonical_type("error"), do: :errors
  defp canonical_type("errors"), do: :errors
  defp canonical_type("context"), do: :context
  defp canonical_type("contexts"), do: :context
  defp canonical_type("note"), do: :notes
  defp canonical_type("notes"), do: :notes
  defp canonical_type("preference"), do: :preferences
  defp canonical_type("preferences"), do: :preferences
  defp canonical_type("research"), do: :research
  defp canonical_type("task"), do: :tasks
  defp canonical_type("tasks"), do: :tasks
  defp canonical_type("project"), do: :projects
  defp canonical_type("projects"), do: :projects
  defp canonical_type(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value) when is_binary(value), do: String.trim(value)
  defp normalize_key(value), do: value

  defp validate_memory_entry(type, key, value) do
    with :ok <- validate_memory_component(:type, type, @max_key_bytes),
         :ok <- validate_memory_component(:key, key, @max_key_bytes),
         :ok <- validate_memory_value(value) do
      :ok
    end
  end

  defp validate_memory_component(name, value, max_bytes) when is_atom(value),
    do: validate_memory_component(name, Atom.to_string(value), max_bytes)

  defp validate_memory_component(name, value, max_bytes) when is_binary(value) do
    cond do
      String.trim(value) == "" -> {:error, "Memory #{name} cannot be empty."}
      byte_size(value) > max_bytes -> {:error, "Memory #{name} is too large."}
      true -> :ok
    end
  end

  defp validate_memory_component(name, _value, _max_bytes),
    do: {:error, "Memory #{name} must be an atom or string."}

  defp validate_memory_value(value) do
    if :erlang.external_size(value) <= @max_value_bytes do
      :ok
    else
      {:error, "Memory value is too large. Store a concise fact or decision instead of raw file contents."}
    end
  end

  defp storable_memory_value?(value) do
    match?(:ok, validate_memory_value(value))
  end

  defp probable_accidental_limit?(value) when is_integer(value), do: value >= @max_limit
  defp probable_accidental_limit?(_value), do: false

  defp clamp_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@max_limit)
  end

  defp clamp_limit(_limit), do: @default_limit

  defp query_to_text(query) do
    query
    |> to_string()
    |> String.downcase()
    |> String.trim()
  end

  defp compact_value(value) when is_binary(value) do
    if byte_size(value) > 1_000 do
      String.slice(value, 0, 1_000) <> "…"
    else
      value
    end
  end

  defp compact_value(value), do: value

  defp parse_git_url(url) do
    url = String.replace_suffix(url, ".git", "")
    parts = String.split(url, [":", "/"])

    case Enum.reverse(parts) do
      [repo, org | _] -> {org, repo}
      _ -> nil
    end
  end
end
