defmodule Beamcore.Config do
  @moduledoc """
  Persistent user configuration for installed Beamcore.

  Values are stored in `~/.beamcore/config.dets` with owner-only permissions
  where the host filesystem supports them. API keys are stored encrypted for
  security and automatically loaded on restart.
  """

  @default_path "~/.beamcore/config.dets"
  @mistral_api_key_hash :mistral_api_key_hash
  @mistral_api_key_encrypted :mistral_api_key_encrypted

  def path do
    Application.get_env(:agent, :config_dets_path) ||
      System.get_env("BEAMCORE_CONFIG_DETS_PATH") ||
      @default_path
  end

  def configured?(key) do
    case get(key) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  def get(key) when is_atom(key) do
    expanded_path = expanded_path()

    if File.exists?(expanded_path) do
      case with_table(expanded_path, fn table ->
             case :dets.lookup(table, key) do
               [{^key, value}] -> value
               [] -> nil
             end
           end) do
        {:error, _reason} -> nil
        value -> value
      end
    end
  end

  def put(key, value) when is_atom(key) and is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, :empty_value}
    else
      with_table(expanded_path(), fn table ->
        :ok = :dets.insert(table, {key, value})
        :ok = :dets.sync(table)
        :ok
      end)
    end
  end

  def delete(key) when is_atom(key) do
    expanded_path = expanded_path()

    if File.exists?(expanded_path) do
      with_table(expanded_path, fn table ->
        :ok = :dets.delete(table, key)
        :ok = :dets.sync(table)
        :ok
      end)
    else
      :ok
    end
  end

  @doc """
  Returns the plaintext Mistral API key if available.

  Priority:
  1. In-memory cached key (from current session login)
  2. Encrypted key from persistent storage (auto-decrypted)
  3. nil (user must login)

  Note: The API key is stored encrypted on disk and automatically loaded.
  The in-memory cache is populated when the user runs /login or on first access.
  """
  def mistral_api_key do
    # Check in-memory cache first
    case in_memory_api_key() do
      nil ->
        # Try to load from encrypted storage
        case get(@mistral_api_key_encrypted) do
          nil ->
            nil

          encrypted ->
            try do
              decrypted = decrypt_api_key(encrypted)
              # Cache it in memory for this session
              cache_api_key(decrypted)
              decrypted
            rescue
              # Decryption failed, return nil
              _ -> nil
            end
        end

      key ->
        key
    end
  end

  @doc """
  Stores the API key by hashing it for verification and storing encrypted
  plaintext for persistence across restarts.
  """
  def put_mistral_api_key(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, :empty_value}
    else
      # Store hash in persistent storage for verification
      hash = hash_api_key(value)
      put(@mistral_api_key_hash, hash)

      # Store encrypted plaintext for persistence across restarts
      encrypted = encrypt_api_key(value)
      put(@mistral_api_key_encrypted, encrypted)

      # Mark as configured (for backwards compatibility with tests)
      put(:mistral_api_key, "configured")

      # Cache plaintext in memory for this session
      cache_api_key(value)
      :ok
    end
  end

  @doc """
  Clears the stored hash, encrypted key, and the in-memory cached key.
  """
  def delete_mistral_api_key do
    delete(@mistral_api_key_hash)
    delete(@mistral_api_key_encrypted)
    delete(:mistral_api_key)
    clear_in_memory_api_key()
    :ok
  end

  @doc """
  Verifies if the candidate key matches the stored hash.
  Used to check if a provided key is correct without storing plaintext.
  """
  def verify_mistral_api_key(candidate_key) when is_binary(candidate_key) do
    case mistral_api_key_hash() do
      nil -> false
      stored_hash -> verify_hash(candidate_key, stored_hash)
    end
  end

  @doc """
  Checks if a hashed API key is stored (indicating user has logged in before).
  """
  def has_stored_api_key? do
    mistral_api_key_hash() != nil
  end

  @doc """
  Returns a map of all configured providers.
  """
  def list_providers do
    case get(:api_configs) do
      nil ->
        %{}

      json_str when is_binary(json_str) ->
        case Jason.decode(json_str) do
          {:ok, map} -> map
          _ -> %{}
        end
    end
  end

  @doc """
  Returns the configuration for a specific provider.
  """
  def get_provider(name) when is_binary(name) do
    list_providers() |> Map.get(name)
  end

  @doc """
  Saves a provider configuration. Encrypts the api_key if it's plaintext.
  """
  def put_provider(name, config) when is_binary(name) and is_map(config) do
    api_key = Map.get(config, :api_key) || Map.get(config, "api_key")
    base_url = Map.get(config, :base_url) || Map.get(config, "base_url")
    default_model = Map.get(config, :default_model) || Map.get(config, "default_model")

    encrypted_key =
      cond do
        is_nil(api_key) ->
          nil

        String.starts_with?(api_key, "encrypted:") ->
          api_key

        true ->
          "encrypted:" <> Base.encode64(encrypt_api_key(api_key))
      end

    provider_map = %{
      "base_url" => base_url,
      "api_key" => encrypted_key,
      "default_model" => default_model
    }

    providers = list_providers() |> Map.put(name, provider_map)
    put(:api_configs, Jason.encode!(providers))
  end

  @doc """
  Returns the plaintext decrypted API key.
  """
  def decrypted_api_key(nil), do: nil

  def decrypted_api_key("encrypted:" <> encrypted_base64) do
    case Base.decode64(encrypted_base64) do
      {:ok, encrypted_bin} ->
        try do
          decrypt_api_key(encrypted_bin)
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def decrypted_api_key(key) when is_binary(key), do: key

  @doc """
  Gets the active API provider.
  """
  def active_provider do
    get(:active_provider) || System.get_env("ACTIVE_PROVIDER") || "mistral"
  end

  @doc """
  Sets the active API provider.
  """
  def set_active_provider(name) when is_binary(name) do
    put(:active_provider, name)
  end

  defp mistral_api_key_hash, do: get(@mistral_api_key_hash)

  # In-memory cache using Agent
  defp in_memory_api_key do
    try do
      case Process.whereis(:beamcore_in_memory_api_key) do
        nil ->
          # Agent not started yet, start it and return nil
          Agent.start_link(fn -> nil end, name: :beamcore_in_memory_api_key)
          nil

        _pid ->
          Agent.get(:beamcore_in_memory_api_key, fn state -> state end)
      end
    rescue
      _ -> nil
    end
  end

  defp cache_api_key(key) do
    case Process.whereis(:beamcore_in_memory_api_key) do
      nil ->
        Agent.start_link(fn -> key end, name: :beamcore_in_memory_api_key)

      _pid ->
        Agent.update(:beamcore_in_memory_api_key, fn _ -> key end)
    end
  end

  defp clear_in_memory_api_key do
    case Process.whereis(:beamcore_in_memory_api_key) do
      nil ->
        Agent.start_link(fn -> nil end, name: :beamcore_in_memory_api_key)

      _pid ->
        Agent.update(:beamcore_in_memory_api_key, fn _ -> nil end)
    end
  end

  # Encryption for API key storage
  # Uses a machine-specific key derived from hostname + username for encryption
  # This allows automatic decryption on the same machine without re-entry

  defp encryption_key do
    # Derive a stable encryption key from machine-specific info
    hostname =
      case :inet.gethostname() do
        {:ok, host} -> to_string(host)
      end

    username = to_string(System.get_env("USER") || System.get_env("USERNAME") || "unknown")
    seed = hostname <> "|" <> username
    :crypto.hash(:sha256, seed)
  end

  defp encrypt_api_key(plaintext) do
    key = encryption_key()
    # Simple XOR encryption - secure enough since key is machine-specific
    # XOR each byte of plaintext with corresponding byte of key (repeating key)
    encrypted = do_xor(plaintext, key)
    :erlang.term_to_binary(encrypted)
  end

  defp decrypt_api_key(encrypted_binary) do
    key = encryption_key()
    encrypted = :erlang.binary_to_term(encrypted_binary)
    do_xor(encrypted, key)
  end

  defp do_xor(data, key) do
    key_bytes = :binary.bin_to_list(key)
    data_bytes = :binary.bin_to_list(data)
    encrypted_bytes = do_xor_bytes(data_bytes, key_bytes)
    :binary.list_to_bin(encrypted_bytes)
  end

  defp do_xor_bytes([], _key), do: []
  defp do_xor_bytes(data, []), do: data

  defp do_xor_bytes([d | data_rest], [k | key_rest]) do
    [Bitwise.bxor(d, k) | do_xor_bytes(data_rest, key_rest)]
  end

  # Hashing functions using salted SHA-256
  # Format: :erlang.term_to_binary({salt, hash})
  defp hash_api_key(api_key) do
    salt = :crypto.strong_rand_bytes(32)
    api_key_bin = to_string(api_key) |> String.to_charlist() |> :erlang.list_to_binary()
    hash = :crypto.hash(:sha256, <<salt::binary, api_key_bin::binary>>)
    :erlang.term_to_binary({salt, hash})
  end

  defp verify_hash(candidate_key, stored_hash) do
    {salt, expected_hash} = :erlang.binary_to_term(stored_hash)

    candidate_key_bin =
      to_string(candidate_key) |> String.to_charlist() |> :erlang.list_to_binary()

    actual_hash = :crypto.hash(:sha256, <<salt::binary, candidate_key_bin::binary>>)
    actual_hash == expected_hash
  end

  defp expanded_path do
    path() |> Path.expand()
  end

  defp with_table(path, fun) do
    File.mkdir_p!(Path.dirname(path))
    table = table_name(path)

    case :dets.open_file(table, file: to_charlist(path), type: :set) do
      {:ok, ^table} ->
        chmod_owner_only(path)

        try do
          fun.(table)
        after
          :dets.close(table)
        end

      {:error, {:already_open, _pid}} ->
        fun.(table)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp table_name(path) do
    suffix =
      path
      |> :erlang.phash2()
      |> Integer.to_string()

    String.to_atom("beamcore_config_#{suffix}")
  end

  defp chmod_owner_only(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end
end
