defmodule Beamcore.Agent.Providers.ImageGeneration do
  @moduledoc """
  Provider dispatcher for image generation.

  The tool layer should not know provider-specific endpoints. It asks this
  module to generate image files, and provider modules decide which API flow is
  needed.
  """

  @default_provider "mistral"

  @type generated_file :: %{
          file_id: binary() | nil,
          file_name: binary() | nil,
          file_type: binary() | nil,
          bytes: binary()
        }

  @spec generate(map()) :: {:ok, [generated_file()]} | {:error, binary()}
  def generate(params) when is_map(params) do
    case provider(params) do
      "mistral" -> Beamcore.Agent.Providers.Mistral.generate_image(params)
      other -> {:error, "Unsupported image provider: #{other}. Supported providers: mistral."}
    end
  end

  def generate(_params), do: {:error, "image generation parameters must be an object."}

  defp provider(params) do
    params
    |> Map.get("provider")
    |> normalize_string()
    |> Kernel.||(env("BEAMCORE_IMAGE_PROVIDER"))
    |> Kernel.||(env("MISTRAL_IMAGE_PROVIDER"))
    |> Kernel.||(@default_provider)
    |> String.downcase()
  end

  defp env(name), do: System.get_env(name) |> normalize_string()

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
