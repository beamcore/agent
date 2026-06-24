defmodule Beamcore.Provider.Auth do
  @moduledoc """
  Provider-neutral authentication for OpenAI-compatible adapters.
  """

  alias Beamcore.Provider.Error

  @cache_table :beamcore_provider_auth_token_cache
  @refresh_margin_ms 60_000
  @default_oauth_ttl_ms 1_800_000

  @type material :: %{headers: [{binary(), binary()}], token: binary() | nil}

  @spec validate_config(map()) :: :ok | {:error, Error.t()}
  def validate_config(config) when is_map(config) do
    case strategy(config) do
      :none -> :ok
      :bearer -> validate_static_token(config, "API key or bearer token")
      :api_key -> validate_static_token(config, "API key")
      :oauth2 -> validate_oauth_config(config)
      other -> error(:invalid_config, "Unsupported auth strategy #{inspect(other)}.")
    end
  end

  @spec material(map(), keyword()) :: {:ok, material()} | {:error, Error.t()}
  def material(config, opts \\ []) when is_map(config) do
    case strategy(config) do
      :none ->
        {:ok, %{headers: [], token: nil}}

      :bearer ->
        with {:ok, token} <- static_token(config) do
          {:ok, bearer_material(token)}
        end

      :api_key ->
        with {:ok, token} <- static_token(config) do
          {:ok, api_key_material(config, token)}
        end

      :oauth2 ->
        with {:ok, token} <- oauth_token(config, opts) do
          {:ok, bearer_material(token)}
        end

      other ->
        error(:invalid_config, "Unsupported auth strategy #{inspect(other)}.")
    end
  end

  @spec headers(map(), keyword()) :: {:ok, [{binary(), binary()}]} | {:error, Error.t()}
  def headers(config, opts \\ []) do
    with {:ok, %{headers: headers}} <- material(config, opts), do: {:ok, headers}
  end

  def clear_cache do
    case :ets.info(@cache_table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@cache_table)
    end
  end

  defp validate_static_token(config, label) do
    case static_token(config) do
      {:ok, _token} ->
        :ok

      {:error, _error} ->
        error(:missing_config, "Provider #{provider_name(config)} is missing #{label}.")
    end
  end

  defp validate_oauth_config(config) do
    cond do
      not present?(token_url(config)) ->
        error(:missing_config, "Provider #{provider_name(config)} is missing OAuth token_url.")

      not present?(oauth_client_id(config)) ->
        error(:missing_config, "Provider #{provider_name(config)} is missing OAuth client_id.")

      not present?(oauth_client_secret(config)) ->
        error(
          :missing_config,
          "Provider #{provider_name(config)} is missing OAuth client_secret."
        )

      true ->
        :ok
    end
  end

  defp oauth_token(config, opts) do
    with :ok <- validate_oauth_config(config) do
      case cached_token(config) do
        {:ok, token} -> {:ok, token}
        _ -> fetch_oauth_token(config, opts)
      end
    end
  end

  defp fetch_oauth_token(config, opts) do
    http_client =
      Keyword.get(opts, :http_client) || Application.get_env(:beamcore, :auth_http_client, Req)

    body = oauth_body(config)
    headers = oauth_headers(config)

    case http_client.post(token_url(config),
           body: body,
           headers: headers,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, body: %{"access_token" => token} = response}}
      when status >= 200 and status < 300 and is_binary(token) ->
        cache_token(config, token, expires_at(response))
        {:ok, token}

      {:ok, %{status: status}} ->
        error(:provider_error, "OAuth token request failed with status #{status}.",
          status: status
        )

      {:error, reason} ->
        error(:unavailable, "OAuth token request failed: #{inspect(reason)}.")
    end
  end

  defp oauth_body(config) do
    base =
      %{"grant_type" => "client_credentials"}
      |> maybe_put("scope", oauth_scope(config))

    body =
      if oauth_client_auth(config) == :body do
        base
        |> Map.put("client_id", oauth_client_id(config))
        |> Map.put("client_secret", oauth_client_secret(config))
      else
        base
      end

    URI.encode_query(body)
  end

  defp oauth_headers(config) do
    headers =
      [
        {"Content-Type", "application/x-www-form-urlencoded"},
        {"Accept", "application/json"}
      ]

    headers =
      if oauth_client_auth(config) == :basic do
        credentials = Base.encode64("#{oauth_client_id(config)}:#{oauth_client_secret(config)}")
        [{"Authorization", "Basic #{credentials}"} | headers]
      else
        headers
      end

    headers
    |> Kernel.++(configured_token_headers(config))
    |> maybe_add_request_id(config)
  end

  defp api_key_material(config, token) do
    header = config_value(config, "api_key_header") || "Authorization"
    prefix = config_value(config, "api_key_prefix") || "Bearer"
    value = if present?(prefix), do: "#{prefix} #{token}", else: token
    %{headers: [{header, value}], token: token}
  end

  defp bearer_material(token),
    do: %{headers: [{"Authorization", "Bearer #{token}"}], token: token}

  defp cached_token(config) do
    ensure_cache()
    key = cache_key(config)

    case :ets.lookup(@cache_table, key) do
      [{^key, token, expires_at}] ->
        if System.system_time(:millisecond) < expires_at - @refresh_margin_ms do
          {:ok, token}
        else
          {:expired, token}
        end

      [] ->
        :miss
    end
  end

  defp cache_token(config, token, expires_at) do
    ensure_cache()
    :ets.insert(@cache_table, {cache_key(config), token, expires_at})
  end

  defp ensure_cache do
    case :ets.info(@cache_table) do
      :undefined -> :ets.new(@cache_table, [:named_table, :public, :set])
      _ -> @cache_table
    end
  end

  defp cache_key(config) do
    [
      token_url(config),
      oauth_client_id(config),
      oauth_scope(config),
      oauth_client_auth(config)
    ]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp expires_at(%{"expires_at" => expires_at}) when is_integer(expires_at) do
    if expires_at < 10_000_000_000, do: expires_at * 1000, else: expires_at
  end

  defp expires_at(%{"expires_in" => expires_in}) when is_integer(expires_in) do
    System.system_time(:millisecond) + expires_in * 1000
  end

  defp expires_at(_response), do: System.system_time(:millisecond) + @default_oauth_ttl_ms

  defp strategy(config) do
    auth = config_value(config, "auth")

    cond do
      is_map(auth) ->
        auth_value(config, "strategy") || auth_value(config, "type") || infer_strategy(config)

      auth in [:none, "none"] ->
        :none

      auth in [:api_key, "api_key", :static_api_key, "static_api_key"] ->
        :api_key

      auth in [:oauth2, "oauth2", :client_credentials, "client_credentials"] ->
        :oauth2

      auth in [:bearer, "bearer", nil] ->
        infer_strategy(config)

      true ->
        auth
    end
    |> normalize_strategy()
  end

  defp infer_strategy(config) do
    if present?(token_url(config)), do: :oauth2, else: :bearer
  end

  defp normalize_strategy(value) when value in [:none, :api_key, :bearer, :oauth2], do: value
  defp normalize_strategy("none"), do: :none
  defp normalize_strategy("api_key"), do: :api_key
  defp normalize_strategy("static_api_key"), do: :api_key
  defp normalize_strategy("bearer"), do: :bearer
  defp normalize_strategy("oauth2"), do: :oauth2
  defp normalize_strategy("client_credentials"), do: :oauth2
  defp normalize_strategy(value), do: value

  defp static_token(config) do
    token =
      config_value(config, "bearer_token") ||
        config_value(config, "access_token") ||
        config_value(config, "api_key") ||
        auth_value(config, "token")

    if present?(token), do: {:ok, token}, else: error(:missing_config, "Missing provider token.")
  end

  defp token_url(config), do: auth_value(config, "token_url") || config_value(config, "token_url")

  defp oauth_client_id(config) do
    auth_value(config, "client_id") || config_value(config, "client_id") ||
      split_api_key(config, 0)
  end

  defp oauth_client_secret(config) do
    auth_value(config, "client_secret") || config_value(config, "client_secret") ||
      split_api_key(config, 1)
  end

  defp oauth_scope(config) do
    value =
      auth_value(config, "scope") || auth_value(config, "scopes") || config_value(config, "scope") ||
        config_value(config, "scopes")

    case value do
      list when is_list(list) -> Enum.join(list, " ")
      binary when is_binary(binary) -> binary
      _ -> nil
    end
  end

  defp oauth_client_auth(config) do
    value =
      auth_value(config, "client_auth") || auth_value(config, "token_auth") ||
        config_value(config, "client_auth") || config_value(config, "token_auth") || :basic

    case value do
      value when value in [:body, "body", :post, "post"] -> :body
      _ -> :basic
    end
  end

  defp configured_token_headers(config) do
    case auth_value(config, "token_headers") || config_value(config, "token_headers") do
      headers when is_map(headers) ->
        Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

      headers when is_list(headers) ->
        Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

      _ ->
        []
    end
  end

  defp maybe_add_request_id(headers, config) do
    case auth_value(config, "token_request_id_header") ||
           config_value(config, "token_request_id_header") do
      name when is_binary(name) ->
        [{name, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)} | headers]

      _ ->
        headers
    end
  end

  defp split_api_key(config, index) do
    case config_value(config, "api_key") do
      value when is_binary(value) ->
        value |> String.split(":", parts: 2) |> Enum.at(index)

      _ ->
        nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp auth_value(config, key) do
    case config_value(config, "auth") do
      auth when is_map(auth) -> Map.get(auth, key) || Map.get(auth, String.to_atom(key))
      _ -> nil
    end
  end

  defp config_value(config, key), do: Map.get(config, key) || Map.get(config, String.to_atom(key))

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp provider_name(config), do: config_value(config, "name") || "configured provider"

  defp error(kind, message, opts \\ []) do
    {:error, Error.exception([kind: kind, message: message] ++ opts)}
  end
end
