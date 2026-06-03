defmodule Beamcore.OpenAI do
  @moduledoc """
  Mistral client boundary.

  `client/0` returns the OpenAI-compatible chat client used by OpenaiEx.
  `post_json/2` and `get_binary/1` cover Mistral-specific REST endpoints
  that OpenaiEx does not expose, such as Agents, Conversations, and Files.

  Keeping both flows here avoids having two separate modules responsible for
  the same API key, base URL, timeouts, and low-level HTTP behavior.
  """

  @http_client Application.compile_env(:agent, :http_client, :httpc)
  @base_url "https://api.mistral.ai/v1"
  @receive_timeout 30_000
  @http_timeout 120_000

  defmodule MissingConfigError do
    defexception message: """
                 Beamcore is not configured yet.

                 Run /login and paste your Mistral API key (stored securely as hash).

                 For development only, you may also set MISTRAL_API_KEY or use .env with make chat.
                 """
  end

  @doc """
  Returns a configured OpenaiEx client for Mistral-compatible chat calls.

  Requires `MISTRAL_API_KEY` or a stored Beamcore config token.
  """
  def client do
    api_key = api_key!()
    base_url = env("MISTRAL_BASE_URL", @base_url)

    OpenaiEx.new(api_key)
    |> OpenaiEx.with_base_url(base_url)
    |> OpenaiEx.with_receive_timeout(@receive_timeout)
  end

  def configured?, do: api_key_value() != nil

  def env_api_key_present?, do: api_key_source() == :env

  def api_key_source do
    {source, _value} = api_key_source_and_value()
    source
  end

  def auth_diagnostics do
    env_token = env("MISTRAL_API_KEY")
    config_token = Beamcore.Config.mistral_api_key() |> normalize_env()
    {source, selected_token} = api_key_source_and_value()
    config_path = Beamcore.Config.path() |> Path.expand()

    %{
      env_token_present?: is_binary(env_token),
      config_token_present?: is_binary(config_token),
      selected_token_source: source,
      selected_token_length: token_length(selected_token),
      selected_token_has_mistral_prefix?: token_prefix?(selected_token),
      base_url: env("MISTRAL_BASE_URL", @base_url),
      model: Beamcore.Agent.Chat.API.default_model(),
      auth_header_present?: is_binary(selected_token),
      auth_header_scheme: if(is_binary(selected_token), do: "Bearer", else: "missing"),
      config_dets_path: config_path,
      config_dets_mode: config_mode(config_path)
    }
  end

  def missing_config_message do
    """
    Beamcore is not configured yet.

    Run /login and paste your Mistral API key (stored securely as hash).

    For development only, you may also set MISTRAL_API_KEY or use .env with make chat.
    """
    |> String.trim()
  end

  @doc """
  POST JSON to a Mistral REST endpoint and return the raw binary body.

  This is used for Mistral APIs that are not represented by OpenaiEx, such as
  the Agents and Conversations endpoints used by image generation.
  """
  def post_json(path, payload) when is_binary(path) and is_map(payload) do
    request(:post, path, Jason.encode!(payload), "application/json", :json)
  end

  @doc """
  Download raw bytes from a Mistral REST endpoint.

  The response body is kept binary-safe so downloaded images are not corrupted
  by string or charlist conversion.
  """
  def get_binary(path) when is_binary(path) do
    request(:get, path, nil, nil, :binary)
  end

  defp request(method, path, body, content_type, response_kind) do
    with {:ok, api_key} <- api_key(),
         {:ok, url} <- url(path) do
      request = request_tuple(url, api_key, body, content_type, response_kind)
      ensure_http_started()

      http_options = [timeout: @http_timeout, autoredirect: true]
      request_options = [body_format: :binary]

      case @http_client.request(method, request, http_options, request_options) do
        {:ok, {{_http, status, _reason}, _headers, response_body}} when status in 200..299 ->
          {:ok, normalize_body(response_body)}

        {:ok, {{_http, status, reason}, _headers, response_body}} ->
          message =
            "Mistral API request failed with status #{status} #{to_string(reason)}: " <>
              preview(response_body)

          {:error, message}

        {:error, reason} ->
          {:error, "Mistral API request failed: #{inspect(reason)}"}
      end
    end
  end

  defp ensure_http_started do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp request_tuple(url, api_key, nil, _content_type, response_kind) do
    {to_charlist(url), auth_headers(api_key, response_kind)}
  end

  defp request_tuple(url, api_key, body, content_type, response_kind) do
    {to_charlist(url), auth_headers(api_key, response_kind), to_charlist(content_type), body}
  end

  defp auth_headers(api_key, :json) do
    [
      {~c"authorization", to_charlist("Bearer #{api_key}")},
      {~c"accept", ~c"application/json"}
    ]
  end

  defp auth_headers(api_key, :binary) do
    [
      {~c"authorization", to_charlist("Bearer #{api_key}")},
      {~c"accept", ~c"*/*"}
    ]
  end

  defp api_key! do
    case api_key_value() do
      nil ->
        raise MissingConfigError

      api_key ->
        api_key
    end
  end

  defp api_key do
    case api_key_value() do
      nil ->
        {:error, missing_config_message()}

      value ->
        {:ok, value}
    end
  end

  defp api_key_value do
    {_source, value} = api_key_source_and_value()
    value
  end

  defp api_key_source_and_value do
    env_token = env("MISTRAL_API_KEY")
    config_token = Beamcore.Config.mistral_api_key() |> normalize_env()

    cond do
      is_binary(env_token) -> {:env, env_token}
      is_binary(config_token) -> {:config, config_token}
      true -> {:missing, nil}
    end
  end

  defp url(path) do
    base_url = env("MISTRAL_BASE_URL", @base_url)
    url = String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")

    {:ok, url}
  end

  defp env(name) do
    name
    |> System.get_env()
    |> normalize_env()
  end

  defp env(name, default) do
    env(name) || default
  end

  defp normalize_env(nil), do: nil

  defp normalize_env(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp token_length(token) when is_binary(token), do: String.length(token)
  defp token_length(_token), do: 0

  defp token_prefix?(token) when is_binary(token), do: String.starts_with?(token, "mistral")
  defp token_prefix?(_token), do: false

  defp config_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Integer.to_string(Bitwise.band(mode, 0o777), 8)
      {:error, _reason} -> "missing"
    end
  end

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp normalize_body(body), do: IO.iodata_to_binary(body)

  defp preview(body) do
    body
    |> normalize_body()
    |> inspect(limit: 20, printable_limit: 200)
  end
end
