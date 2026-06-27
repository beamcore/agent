defmodule Beamcore.Provider.Auth do
  @moduledoc """
  Provider-neutral authentication for OpenAI-compatible adapters.
  """

  alias Beamcore.Provider.Error

  @cache_table :beamcore_provider_auth_token_cache
  @refresh_margin_ms 60_000
  @default_oauth_ttl_ms 1_800_000

  @type material :: %{headers: [{binary(), binary()}], token: binary() | nil}

  @doc false
  def strategy(config) when is_map(config) do
    auth = config_value(config, "auth")

    cond do
      is_map(auth) ->
        auth_value(config, "strategy") || auth_value(config, "type") || infer_strategy(config)

      auth in [:none, "none"] ->
        :none

      auth in [:api_key, "api_key", :static_api_key, "static_api_key"] ->
        :api_key

      auth in [
        :oauth2,
        "oauth2",
        :oauth2_client_credentials,
        "oauth2_client_credentials",
        :client_credentials,
        "client_credentials"
      ] ->
        :oauth2_client_credentials

      auth in [:bearer, "bearer", nil] ->
        infer_strategy(config)

      true ->
        auth
    end
    |> normalize_strategy()
  end

  @spec validate_config(map()) :: :ok | {:error, Error.t()}
  def validate_config(config) when is_map(config) do
    case strategy(config) do
      :none -> :ok
      :bearer -> validate_static_token(config, "API key or bearer token")
      :api_key -> validate_static_token(config, "API key")
      :oauth2_client_credentials -> validate_oauth_config(config)
      :google_adc -> validate_google_adc_config(config)
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

      :oauth2_client_credentials ->
        with {:ok, token} <- oauth_token(config, opts) do
          {:ok, bearer_material(token)}
        end

      :google_adc ->
        with {:ok, token} <- google_adc_token(config, opts) do
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

  @doc false
  def request_options(config, tls_mode \\ :configured) when is_map(config) do
    case transport_options(config, tls_mode) do
      [] -> []
      transport_opts -> [connect_options: [transport_opts: transport_opts]]
    end
  end

  @doc false
  def tls_auto?(config), do: ssl_verify_mode(config) == :auto

  @doc false
  def unknown_ca_error?(%Req.TransportError{reason: reason}), do: unknown_ca_error?(reason)

  def unknown_ca_error?(reason) do
    reason
    |> inspect()
    |> String.contains?("unknown_ca")
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

      present?(oauth_basic_credential(config)) ->
        :ok

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

  defp validate_google_adc_config(config) do
    case google_adc_credentials(config) do
      {:ok, _credentials, _path} ->
        :ok

      {:error, message} ->
        error(:missing_config, message)
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

    config
    |> post_oauth_token(http_client, body, headers, :configured)
    |> maybe_retry_unknown_ca(config, fn ->
      post_oauth_token(config, http_client, body, headers, :insecure)
    end)
    |> case do
      {:ok, %{status: status, body: %{"access_token" => token} = response}}
      when status >= 200 and status < 300 and is_binary(token) ->
        cache_token(config, token, expires_at(response))
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        error(
          :provider_error,
          "OAuth token request failed with status #{status}: #{inspect(body)}.",
          status: status
        )

      {:error, reason} ->
        error(:unavailable, "OAuth token request failed: #{inspect(reason)}.")
    end
  end

  defp google_adc_token(config, opts) do
    with :ok <- validate_google_adc_config(config) do
      case cached_token(config) do
        {:ok, token} -> {:ok, token}
        _ -> fetch_google_adc_token(config, opts)
      end
    end
  end

  defp fetch_google_adc_token(config, opts) do
    http_client =
      Keyword.get(opts, :http_client) || Application.get_env(:beamcore, :auth_http_client, Req)

    with {:ok, credentials, _path} <- google_adc_credentials(config),
         {:ok, token_url, body, headers} <- google_adc_token_request(config, credentials) do
      http_client.post(token_url,
        body: URI.encode_query(body),
        headers: headers,
        receive_timeout: 15_000
      )
      |> case do
        {:ok, %{status: status, body: %{"access_token" => token} = response}}
        when status >= 200 and status < 300 and is_binary(token) ->
          cache_token(config, token, expires_at(response))
          {:ok, token}

        {:ok, %{status: status, body: body}} ->
          error(
            :provider_error,
            "Google ADC token request failed with status #{status}: #{inspect(body)}.",
            status: status
          )

        {:error, reason} ->
          error(:unavailable, "Google ADC token request failed: #{inspect(reason)}.")
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, message} when is_binary(message) ->
        error(:missing_config, message)

      {:error, reason} ->
        error(:invalid_config, "Google ADC configuration failed: #{inspect(reason)}.")
    end
  end

  defp google_adc_token_request(config, %{"type" => "service_account"} = credentials) do
    token_url = credentials["token_uri"] || "https://oauth2.googleapis.com/token"

    with {:ok, assertion} <- google_service_account_assertion(config, credentials, token_url) do
      {:ok, token_url,
       %{
         "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
         "assertion" => assertion
       }, google_token_headers()}
    end
  end

  defp google_adc_token_request(_config, %{"type" => "authorized_user"} = credentials) do
    token_url = credentials["token_uri"] || "https://oauth2.googleapis.com/token"

    required = ["client_id", "client_secret", "refresh_token"]

    case Enum.find(required, &(not present?(credentials[&1]))) do
      nil ->
        {:ok, token_url,
         %{
           "grant_type" => "refresh_token",
           "client_id" => credentials["client_id"],
           "client_secret" => credentials["client_secret"],
           "refresh_token" => credentials["refresh_token"]
         }, google_token_headers()}

      field ->
        {:error, "Google ADC authorized_user credentials are missing #{field}."}
    end
  end

  defp google_adc_token_request(_config, credentials) do
    type = Map.get(credentials, "type") || "unknown"
    {:error, "Google ADC credential type #{inspect(type)} is not supported."}
  end

  defp google_service_account_assertion(config, credentials, token_url) do
    now = System.system_time(:second)

    claims = %{
      "iss" => credentials["client_email"],
      "scope" => google_scope(config),
      "aud" => token_url,
      "iat" => now,
      "exp" => now + 3600
    }

    cond do
      not present?(credentials["client_email"]) ->
        {:error, "Google service account credentials are missing client_email."}

      not present?(credentials["private_key"]) ->
        {:error, "Google service account credentials are missing private_key."}

      true ->
        header = %{"alg" => "RS256", "typ" => "JWT"}
        signing_input = "#{base64url_json(header)}.#{base64url_json(claims)}"

        with {:ok, key} <- decode_google_private_key(credentials["private_key"]) do
          signature =
            signing_input
            |> :public_key.sign(:sha256, key)
            |> base64url()

          {:ok, "#{signing_input}.#{signature}"}
        end
    end
  end

  defp decode_google_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [] -> {:error, "Google service account private_key is not a valid PEM."}
    end
  rescue
    _ -> {:error, "Google service account private_key could not be decoded."}
  end

  defp google_token_headers do
    [{"Content-Type", "application/x-www-form-urlencoded"}, {"Accept", "application/json"}]
  end

  defp post_oauth_token(config, http_client, body, headers, tls_mode) do
    http_client.post(
      token_url(config),
      [body: body, headers: headers, receive_timeout: 15_000] ++ request_options(config, tls_mode)
    )
  end

  defp maybe_retry_unknown_ca({:error, reason}, config, retry_fun) do
    if tls_auto?(config) and unknown_ca_error?(reason), do: retry_fun.(), else: {:error, reason}
  end

  defp maybe_retry_unknown_ca(result, _config, _retry_fun), do: result

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
      cond do
        present?(oauth_basic_credential(config)) ->
          [{"Authorization", basic_header_value(oauth_basic_credential(config))} | headers]

        oauth_client_auth(config) == :basic ->
          credentials = Base.encode64("#{oauth_client_id(config)}:#{oauth_client_secret(config)}")
          [{"Authorization", "Basic #{credentials}"} | headers]

        true ->
          headers
      end

    headers
    |> Kernel.++(configured_token_headers(config))
    |> maybe_add_request_id(config)
  end

  defp transport_options(config, tls_mode) do
    []
    |> maybe_put_ssl_verify(config, tls_mode)
    |> maybe_put_cacertfile(config)
  end

  defp maybe_put_ssl_verify(opts, _config, :insecure),
    do: Keyword.put(opts, :verify, :verify_none)

  defp maybe_put_ssl_verify(opts, config, :configured) do
    case ssl_verify_mode(config) do
      :disabled -> Keyword.put(opts, :verify, :verify_none)
      _ -> opts
    end
  end

  defp ssl_verify_mode(config) do
    case first_config_value(config, "ssl_verify") do
      false -> :disabled
      "false" -> :disabled
      "FALSE" -> :disabled
      "0" -> :disabled
      "no" -> :disabled
      "NO" -> :disabled
      true -> :strict
      "true" -> :strict
      "TRUE" -> :strict
      "1" -> :strict
      "yes" -> :strict
      "YES" -> :strict
      "auto" -> :auto
      "AUTO" -> :auto
      nil -> :strict
      "" -> :strict
      _ -> :strict
    end
  end

  defp maybe_put_cacertfile(opts, config) do
    case first_config_value(config, "cacertfile") do
      path when is_binary(path) and path != "" -> Keyword.put(opts, :cacertfile, path)
      _ -> opts
    end
  end

  defp first_config_value(config, key) do
    case fetch_config_value(config, key) do
      {:ok, value} ->
        value

      :error ->
        case fetch_auth_value(config, key) do
          {:ok, value} -> value
          :error -> nil
        end
    end
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
      strategy(config),
      token_url(config),
      oauth_client_id(config),
      oauth_scope(config),
      oauth_client_auth(config),
      google_adc_credentials_file(config),
      google_scope(config)
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

  defp infer_strategy(config) do
    if present?(token_url(config)), do: :oauth2_client_credentials, else: :bearer
  end

  defp normalize_strategy(value)
       when value in [:none, :api_key, :bearer, :oauth2_client_credentials, :google_adc],
       do: value

  defp normalize_strategy(:oauth2), do: :oauth2_client_credentials
  defp normalize_strategy(:client_credentials), do: :oauth2_client_credentials
  defp normalize_strategy("none"), do: :none
  defp normalize_strategy("api_key"), do: :api_key
  defp normalize_strategy("static_api_key"), do: :api_key
  defp normalize_strategy("bearer"), do: :bearer
  defp normalize_strategy("oauth2"), do: :oauth2_client_credentials
  defp normalize_strategy("oauth2_client_credentials"), do: :oauth2_client_credentials
  defp normalize_strategy("client_credentials"), do: :oauth2_client_credentials
  defp normalize_strategy("google_adc"), do: :google_adc
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

  defp oauth_basic_credential(config) do
    auth_value(config, "basic_credential") ||
      auth_value(config, "authorization_key") ||
      config_value(config, "oauth_basic_credential") ||
      config_value(config, "authorization_key") ||
      raw_api_key_credential(config)
  end

  defp raw_api_key_credential(config) do
    explicit_client? =
      present?(auth_value(config, "client_id") || config_value(config, "client_id"))

    explicit_secret? =
      present?(auth_value(config, "client_secret") || config_value(config, "client_secret"))

    case config_value(config, "api_key") do
      value when is_binary(value) ->
        if explicit_client? or explicit_secret? or String.contains?(value, ":") do
          nil
        else
          value
        end

      _ ->
        nil
    end
  end

  defp basic_header_value("Basic " <> _ = value), do: value
  defp basic_header_value("basic " <> rest), do: "Basic " <> rest
  defp basic_header_value(value), do: "Basic #{value}"

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

  defp google_scope(config) do
    oauth_scope(config) || "https://www.googleapis.com/auth/cloud-platform"
  end

  defp google_adc_credentials(config) do
    case google_adc_credentials_file(config) do
      path when is_binary(path) ->
        path
        |> Path.expand()
        |> read_google_credentials()

      nil ->
        {:error,
         "Google ADC credentials were not found. Set GOOGLE_APPLICATION_CREDENTIALS or configure gcloud application-default credentials."}
    end
  end

  defp google_adc_credentials_file(config) do
    explicit =
      auth_value(config, "credentials_file") ||
        auth_value(config, "credential_file") ||
        config_value(config, "google_application_credentials") ||
        config_value(config, "credentials_file")

    cond do
      present?(explicit) ->
        explicit

      present?(System.get_env("GOOGLE_APPLICATION_CREDENTIALS")) ->
        System.get_env("GOOGLE_APPLICATION_CREDENTIALS")

      true ->
        well_known_google_adc_file()
    end
  end

  defp well_known_google_adc_file do
    home = user_home()

    candidates =
      [
        System.get_env("CLOUDSDK_CONFIG") &&
          Path.join(System.get_env("CLOUDSDK_CONFIG"), "application_default_credentials.json"),
        home && Path.join([home, ".config", "gcloud", "application_default_credentials.json"])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find(candidates, &File.exists?/1)
  end

  defp user_home do
    System.user_home!()
  rescue
    _ -> nil
  end

  defp read_google_credentials(path) do
    with true <-
           File.exists?(path) || {:error, "Google ADC credentials file was not found: #{path}."},
         {:ok, contents} <- File.read(path),
         {:ok, credentials} <- Jason.decode(contents),
         true <-
           is_map(credentials) ||
             {:error, "Google ADC credentials file must contain a JSON object."} do
      {:ok, credentials, path}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Google ADC credentials file is not valid JSON: #{Exception.message(error)}."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Google ADC credentials file could not be read: #{inspect(reason)}."}
    end
  end

  defp base64url_json(value), do: value |> Jason.encode!() |> base64url()

  defp base64url(value), do: Base.url_encode64(value, padding: false)

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
        [{name, request_id()} | headers]

      _ ->
        headers
    end
  end

  defp request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    [
      hex(a, 8),
      hex(b, 4),
      hex(c, 4),
      hex(d, 4),
      hex(e, 12)
    ]
    |> Enum.join("-")
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
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

  defp fetch_auth_value(config, key) do
    case config_value(config, "auth") do
      auth when is_map(auth) -> fetch_config_value(auth, key)
      _ -> :error
    end
  end

  defp fetch_config_value(config, key) do
    cond do
      Map.has_key?(config, key) -> {:ok, Map.fetch!(config, key)}
      Map.has_key?(config, String.to_atom(key)) -> {:ok, Map.fetch!(config, String.to_atom(key))}
      true -> :error
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp provider_name(config), do: config_value(config, "name") || "configured provider"

  defp error(kind, message, opts \\ []) do
    {:error, Error.exception([kind: kind, message: message] ++ opts)}
  end
end
