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
    api_key =
      case System.get_env("MISTRAL_API_KEY") do
        nil -> raise "MISTRAL_API_KEY environment variable not set"
        key -> key
      end

    base_url = System.get_env("MISTRAL_BASE_URL", @base_url)

    OpenaiEx.new(api_key)
    |> OpenaiEx.with_base_url(base_url)
    |> OpenaiEx.with_receive_timeout(30_000)
  end
end
