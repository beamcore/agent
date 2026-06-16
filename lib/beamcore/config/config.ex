defmodule Beamcore.Config do
  @moduledoc """
  Supervised owner of Beamcore's persistent user configuration.

  The process owns `config.dets`, keeps a small in-memory secret cache, and
  serializes configuration changes. Secrets are encrypted at rest with a
  machine-bound AES-256-GCM key and the file is stored with mode `0600`
  where supported. This is local at-rest protection, not a replacement for an
  operating-system keychain.
  """

  use GenServer

  @default_path "~/.beamcore/config.dets"
  @table :beamcore_config_store
  @cipher_version 1
  @iv_bytes 12
  @tag_bytes 16

  # -- lifecycle -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    case open_store(expanded_path()) do
      {:ok, path} -> {:ok, %{path: path, cache: %{}}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # -- public API ----------------------------------------------------------

  def path do
    Application.get_env(:agent, :config_dets_path) || @default_path
  end

  def configured?(key) when is_atom(key) do
    case get(key) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  def get(key) when is_atom(key), do: call({:get, key}, nil)

  def put(key, value) when is_atom(key) and is_binary(value) do
    value = String.trim(value)

    if value == "",
      do: {:error, :empty_value},
      else: call({:put, key, value}, {:error, :unavailable})
  end

  def delete(key) when is_atom(key), do: call({:delete, key}, :ok)

  def get_setting(key, default \\ nil) when is_atom(key) do
    case get(key) do
      nil ->
        default

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {int, ""} when int > 0 -> int
          _ -> value
        end
    end
  end

  def put_setting(key, value) when is_atom(key) and is_integer(value) do
    put(key, Integer.to_string(value))
  end

  def put_setting(key, value) when is_atom(key) and is_binary(value) do
    put(key, value)
  end

  def list_providers do
    case get(:api_configs) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, providers} when is_map(providers) -> providers
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  def get_provider(name) when is_binary(name), do: Map.get(list_providers(), name)

  def put_provider(name, config) when is_binary(name) and is_map(config) do
    call({:put_provider, name, config}, {:error, :unavailable})
  end

  def decrypted_api_key(nil), do: nil

  def decrypted_api_key("encrypted:" <> encoded) do
    with {:ok, encrypted} <- Base.decode64(encoded),
         {:ok, value} <- decrypt_secret(encrypted) do
      value
    else
      _ -> nil
    end
  end

  def decrypted_api_key(key) when is_binary(key), do: key

  def active_provider do
    get(:active_provider)
  end

  def set_active_provider(name) when is_binary(name), do: put(:active_provider, name)

  def active_provider(screen_type) do
    screen_type = screen_type || :agent

    case get(:"active_provider_#{screen_type}") do
      nil -> default_provider_for_screen(screen_type)
      value -> value
    end
  end

  def set_active_provider(screen_type, name) when is_binary(name) do
    screen_type = screen_type || :agent
    put(:"active_provider_#{screen_type}", name)

    if screen_type == :agent do
      set_active_provider(name)
    end
  end

  def active_model(screen_type) do
    screen_type = screen_type || :agent

    case get(:"active_model_#{screen_type}") do
      nil -> default_model_for_screen(screen_type)
      value -> value
    end
  end

  def set_active_model(screen_type, model) when is_binary(model) do
    screen_type = screen_type || :agent
    put(:"active_model_#{screen_type}", model)
  end

  def mode_selection(screen_type) do
    settings = Beamcore.Agent.Chat.ModeSettings.resolve(screen_type)
    %{provider: settings.provider, model: settings.model, mode: settings.mode}
  end

  defp default_provider_for_screen(_other), do: active_provider()

  defp default_model_for_screen(_other), do: Beamcore.Agent.Chat.API.default_model()

  # -- callbacks -----------------------------------------------------------

  @impl true
  def handle_call(message, _from, state) do
    with {:ok, state} <- ensure_store(state) do
      dispatch(message, state)
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch({:get, key}, state) do
    value = lookup(key)
    {:reply, value, state}
  end

  defp dispatch({:put, key, value}, state) do
    reply = persist([{key, value}])
    {:reply, reply, state}
  end

  defp dispatch({:delete, key}, state) do
    :ok = :dets.delete(@table, key)
    :ok = :dets.sync(@table)
    {:reply, :ok, %{state | cache: Map.delete(state.cache, key)}}
  end

  defp dispatch({:put_provider, name, config}, state) do
    api_key = Map.get(config, :api_key) || Map.get(config, "api_key")
    base_url = Map.get(config, :base_url) || Map.get(config, "base_url")
    default_model = Map.get(config, :default_model) || Map.get(config, "default_model")
    context_window = Map.get(config, :context_window) || Map.get(config, "context_window")

    max_output_tokens =
      Map.get(config, :max_output_tokens) || Map.get(config, "max_output_tokens")

    tokenizer = Map.get(config, :tokenizer) || Map.get(config, "tokenizer")

    encrypted_key =
      cond do
        is_nil(api_key) -> nil
        String.starts_with?(api_key, "encrypted:") -> api_key
        true -> "encrypted:" <> Base.encode64(encrypt_secret(api_key))
      end

    provider =
      %{
        "base_url" => base_url,
        "api_key" => encrypted_key,
        "default_model" => default_model,
        "context_window" => context_window,
        "max_output_tokens" => max_output_tokens,
        "tokenizer" => tokenizer
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    providers =
      case lookup(:api_configs) do
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, values} when is_map(values) -> values
            _ -> %{}
          end

        _ ->
          %{}
      end
      |> Map.put(name, provider)

    reply = persist([{:api_configs, Jason.encode!(providers)}])
    {:reply, reply, state}
  end

  # -- store ownership -----------------------------------------------------

  defp call(message, fallback) do
    case Process.whereis(__MODULE__) do
      nil -> fallback
      _pid -> GenServer.call(__MODULE__, message, :infinity)
    end
  end

  defp ensure_store(%{path: current} = state) do
    desired = expanded_path()

    if desired == current do
      {:ok, state}
    else
      :dets.close(@table)

      case open_store(desired) do
        {:ok, path} -> {:ok, %{state | path: path, cache: %{}}}
        {:error, reason} -> {:error, reason, %{state | path: nil, cache: %{}}}
      end
    end
  end

  defp open_store(path) do
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, file: to_charlist(path), type: :set, repair: true) do
      {:ok, @table} ->
        chmod_owner_only(path)
        {:ok, path}

      {:error, {:already_open, @table}} ->
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup(key) do
    case :dets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp persist(entries) do
    :ok = :dets.insert(@table, entries)
    :ok = :dets.sync(@table)
    :ok
  rescue
    error -> {:error, error}
  end

  defp expanded_path do
    p = path()

    case File.cwd() do
      {:ok, cwd} -> Path.expand(p, cwd)
      {:error, _} -> Path.expand(p, System.user_home!())
    end
  end

  defp chmod_owner_only(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  # -- secret protection ---------------------------------------------------

  defp encryption_key do
    hostname =
      case :inet.gethostname() do
        {:ok, host} -> to_string(host)
      end

    username = System.get_env("USER") || System.get_env("USERNAME") || "default"
    :crypto.hash(:sha256, "beamcore-config-v1|#{hostname}|#{username}")
  end

  defp legacy_encryption_key do
    hostname =
      case :inet.gethostname() do
        {:ok, host} -> to_string(host)
      end

    username = System.get_env("USER") || System.get_env("USERNAME") || "default"
    :crypto.hash(:sha256, hostname <> "|" <> username)
  end

  defp encrypt_secret(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    aad = "beamcore-config"

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, encryption_key(), iv, plaintext, aad, true)

    <<@cipher_version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
      ciphertext::binary>>
  end

  defp decrypt_secret(
         <<@cipher_version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
           ciphertext::binary>>
       ) do
    aad = "beamcore-config"

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           encryption_key(),
           iv,
           ciphertext,
           aad,
           tag,
           false
         ) do
      :error -> {:error, :decrypt_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  rescue
    _ -> {:error, :decrypt_failed}
  end

  # Migration support for the previous machine-key XOR format.
  defp decrypt_secret(legacy) when is_binary(legacy) do
    try do
      encrypted = :erlang.binary_to_term(legacy, [:safe])
      {:ok, xor_bytes(encrypted, legacy_encryption_key())}
    rescue
      _ -> {:error, :decrypt_failed}
    end
  end

  defp xor_bytes(data, key) do
    key_bytes = :binary.bin_to_list(key)

    data
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} ->
      Bitwise.bxor(byte, Enum.at(key_bytes, rem(index, length(key_bytes))))
    end)
    |> :binary.list_to_bin()
  end
end
