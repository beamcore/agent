defmodule Beamcore.Provider.OllamaDiscovery do
  @moduledoc """
  Native Ollama health and model discovery helpers.

  Chat still uses the OpenAI-compatible `/v1` protocol; this module only probes
  Ollama's model endpoints for local helper availability.
  """

  @http_client Application.compile_env(:agent, :http_client, :httpc)
  @default_base_url "http://127.0.0.1:11434/v1"
  @doc """
  Lists models exposed by the configured Ollama server.

  No model is guessed or selected automatically; callers must persist an
  explicit user choice.
  """
  def list_models(base_url \\ @default_base_url) do
    base_url =
      System.get_env("OLLAMA_BASE_URL") || System.get_env("BEAMCORE_OLLAMA_BASE_URL") ||
        base_url || @default_base_url

    base_url = String.trim_trailing(base_url, "/")

    case get_request("#{base_url}/models") do
      {:ok, %{"data" => models}} when is_list(models) ->
        {:ok, models |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()}

      _ ->
        root_url = String.replace(base_url, ~r|/v1$|, "")

        case get_request("#{root_url}/api/tags") do
          {:ok, %{"models" => models}} when is_list(models) ->
            {:ok, models |> Enum.map(& &1["name"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()}

          _ ->
            {:error, :unavailable}
        end
    end
  end

  def check_availability(base_url, model) do
    base_url = String.trim_trailing(base_url, "/")

    case get_request("#{base_url}/models") do
      {:ok, %{"data" => models}} when is_list(models) ->
        Enum.any?(models, fn m -> m["id"] == model end)

      _ ->
        root_url = String.replace(base_url, ~r|/v1$|, "")

        case get_request("#{root_url}/api/tags") do
          {:ok, %{"models" => models}} when is_list(models) ->
            Enum.any?(models, fn m -> m["name"] == model end)

          _ ->
            false
        end
    end
  end

  defp get_request(url) do
    request = {to_charlist(url), []}

    case @http_client.request(:get, request, [timeout: 300], []) do
      {:ok, {{_http, status, _reason}, _headers, body}} when status in 200..299 ->
        Jason.decode(normalize_body(body))

      _ ->
        {:error, :failed}
    end
  end

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp normalize_body(body), do: IO.iodata_to_binary(body)
end
