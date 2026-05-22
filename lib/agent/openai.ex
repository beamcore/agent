defmodule Beamcore.Agent.OpenAI do
  @moduledoc """
  Mistral API client configuration using OpenaiEx.
  """

  @base_url "https://api.mistral.ai/v1"

  @doc """
  Returns a configured OpenaiEx client for Mistral API.

  Requires MISTRAL_API_KEY environment variable to be set.
  """
  def client do
    api_key = api_key!()
    base_url = env("MISTRAL_BASE_URL", @base_url)

    OpenaiEx.new(api_key)
    |> OpenaiEx.with_base_url(base_url)
    |> OpenaiEx.with_receive_timeout(30_000)
  end

  defp api_key! do
    case env("MISTRAL_API_KEY") do
      nil ->
        raise "MISTRAL_API_KEY environment variable is required for Mistral API calls."

      api_key ->
        api_key
    end
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
end
