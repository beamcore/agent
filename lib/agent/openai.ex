defmodule Beamcore.Agent.OpenAI do
  @moduledoc """
  Mistral client boundary used by the agent.

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

  @doc """
  Returns a configured OpenaiEx client for Mistral-compatible chat calls.

  Requires `MISTRAL_API_KEY` to be set.
  """
  def client do
    api_key = api_key!()
    base_url = env("MISTRAL_BASE_URL", @base_url)

    OpenaiEx.new(api_key)
    |> OpenaiEx.with_base_url(base_url)
    |> OpenaiEx.with_receive_timeout(@receive_timeout)
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
    case env("MISTRAL_API_KEY") do
      nil ->
        raise "MISTRAL_API_KEY environment variable is required for Mistral API calls."

      api_key ->
        api_key
    end
  end

  defp api_key do
    case env("MISTRAL_API_KEY") do
      nil ->
        {:error, "MISTRAL_API_KEY environment variable is required for Mistral API calls."}

      value ->
        {:ok, value}
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

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp normalize_body(body), do: IO.iodata_to_binary(body)

  defp preview(body) do
    body
    |> normalize_body()
    |> inspect(limit: 20, printable_limit: 200)
  end
end
