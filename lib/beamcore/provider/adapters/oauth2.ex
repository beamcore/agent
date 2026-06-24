defmodule Beamcore.Provider.Adapters.OAuth2 do
  @moduledoc false

  @behaviour Beamcore.Provider

  alias Beamcore.Provider.{Error, Adapters.OpenAICompatible}

  @token_ttl_ms 1800_000

  @completions_module Application.compile_env(
                        :beamcore,
                        :completions_module,
                        OpenaiEx.Chat.Completions
                      )

  @impl true
  def id, do: :oauth2

  @impl true
  defdelegate list_models(config), to: OpenAICompatible
  @impl true
  defdelegate capabilities(model, config), to: OpenAICompatible

  @impl true
  def validate_config(config) do
    cond do
      not is_binary(api_key(config)) ->
        {:error,
         Error.exception(kind: :missing_config, message: "Missing client_id:client_secret.")}

      not is_binary(base_url(config)) ->
        {:error, Error.exception(kind: :missing_config, message: "Missing base_url.")}

      not is_binary(token_url(config)) ->
        {:error, Error.exception(kind: :missing_config, message: "Missing token_url.")}

      true ->
        :ok
    end
  end

  @impl true
  def chat(request, config) do
    with {:ok, token} <- ensure_token(config),
         {:ok, params} <- OpenAICompatible.params(request) do
      client =
        OpenaiEx.new(token)
        |> OpenaiEx.with_base_url(base_url(config))
        |> OpenaiEx.with_receive_timeout(Map.get(config, :receive_timeout, 60_000))

      @completions_module.create(client, params)
      |> normalize()
    end
  end

  @impl true
  def stream(_request, _receiver, _config) do
    {:error, Error.exception(kind: :unsupported_capability)}
  end

  # -- OAuth2 token management -------------------------------------------------

  defp ensure_token(config) do
    case cached_token(config) do
      {:ok, token} -> {:ok, token}
      _ -> fetch_token(config)
    end
  end

  defp fetch_token(config) do
    case String.split(api_key(config), ":", parts: 2) do
      [client_id, client_secret] ->
        do_fetch_token(client_id, client_secret, config)

      _ ->
        {:error,
         Error.exception(kind: :bad_config, message: "Expected client_id:client_secret format.")}
    end
  end

  defp do_fetch_token(client_id, client_secret, config) do
    scope = Map.get(config, "scope") || Map.get(config, :scope) || "GIGACHAT_API_PERS"

    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "scope" => scope
      })

    auth = Base.encode64("#{client_id}:#{client_secret}")

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"},
      {"Authorization", "Basic #{auth}"},
      {"RqUID", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}
    ]

    case Req.post(token_url(config), body: body, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"access_token" => token} = resp}} ->
        expires_at = resp["expires_at"] || System.system_time(:millisecond) + @token_ttl_ms
        cache_token(config, token, expires_at)
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error,
         Error.exception(
           kind: :auth_failed,
           message: "OAuth2 failed (#{status}): #{inspect(body)}"
         )}

      {:error, reason} ->
        {:error,
         Error.exception(kind: :network_error, message: "OAuth2 error: #{inspect(reason)}")}
    end
  end

  # -- Token cache (ETS) -------------------------------------------------------

  @cache_table :oauth2_token_cache

  defp ensure_cache do
    case :ets.info(@cache_table) do
      :undefined -> :ets.new(@cache_table, [:named_table, :public, :set])
      _ -> @cache_table
    end
  end

  defp cached_token(config) do
    ensure_cache()
    key = cache_key(config)

    case :ets.lookup(@cache_table, key) do
      [{^key, token, expires_at}] ->
        if System.system_time(:millisecond) < expires_at - 60_000,
          do: {:ok, token},
          else: {:expired, token}

      [] ->
        :miss
    end
  end

  defp cache_token(config, token, expires_at) do
    ensure_cache()
    :ets.insert(@cache_table, {cache_key(config), token, expires_at})
  end

  defp cache_key(config), do: api_key(config) || "default"

  # -- Helpers -----------------------------------------------------------------

  defp api_key(config), do: Map.get(config, "api_key") || Map.get(config, :api_key)
  defp base_url(config), do: Map.get(config, "base_url") || Map.get(config, :base_url)
  defp token_url(config), do: Map.get(config, "token_url") || Map.get(config, :token_url)

  defp normalize({:ok, response}), do: {:ok, response}
  defp normalize({:error, error}), do: {:error, error}
end
