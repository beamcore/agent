defmodule Beamcore.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.{Capabilities, Error, Registry}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_provider_registry_#{System.unique_integer([:positive])}.dets"
      )

    previous_path = Application.get_env(:beamcore, :config_dets_path)
    Application.put_env(:beamcore, :config_dets_path, path)

    on_exit(fn ->
      restore_config_path(previous_path)
      File.rm(path)
    end)

    :ok
  end

  test "lists default providers with provider-neutral capabilities" do
    providers = Registry.list()

    assert Enum.any?(providers, &(&1.name == "openai"))
    refute Enum.any?(providers, &(&1.name == "ollama"))

    openai = Enum.find(providers, &(&1.name == "openai"))
    assert openai.requires_api_key?
    assert openai.adapter == Beamcore.Provider.Adapters.OpenAICompatible
    assert %Capabilities{tool_calls: true, local: false} = openai.capabilities
  end

  test "custom providers select the OpenAI-compatible adapter without atom creation" do
    assert :ok =
             Beamcore.Config.put_provider("custom-provider", %{
               api_key: "secret",
               base_url: "https://example.test/v1",
               default_model: "model-a"
             })

    provider = Registry.get("custom-provider")

    assert provider.id == :openai_compatible
    assert provider.adapter == Beamcore.Provider.Adapters.OpenAICompatible
    assert provider.configured?
    assert provider.base_url == "https://example.test/v1"
    assert provider.default_model == "model-a"
  end

  test "custom OAuth2 providers still use the OpenAI-compatible adapter" do
    assert :ok =
             Beamcore.Config.put_provider("oauth-compatible", %{
               auth: :oauth2,
               token_url: "https://auth.example/token",
               client_id: "client",
               client_secret: "secret",
               base_url: "https://oauth-compatible.example/v1",
               default_model: "chat-model"
             })

    provider = Registry.get("oauth-compatible")

    assert provider.id == :openai_compatible
    assert provider.adapter == Beamcore.Provider.Adapters.OpenAICompatible
    assert provider.auth == "oauth2"
    assert provider.configured?
    assert provider.base_url == "https://oauth-compatible.example/v1"
  end

  test "custom Google Vertex ADC provider uses OpenAI-compatible adapter without API key" do
    credentials_path = google_adc_credentials_file()

    assert :ok =
             Beamcore.Config.put_provider("google-vertex", %{
               auth: %{
                 strategy: :google_adc,
                 credentials_file: credentials_path,
                 scope: "https://www.googleapis.com/auth/cloud-platform"
               },
               base_url:
                 "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1/endpoints/openapi",
               default_model: "google/gemini-2.5-flash"
             })

    provider = Registry.get("google-vertex")

    assert provider.id == :openai_compatible
    assert provider.adapter == Beamcore.Provider.Adapters.OpenAICompatible

    assert provider.auth == %{
             "credentials_file" => credentials_path,
             "scope" => "https://www.googleapis.com/auth/cloud-platform",
             "strategy" => "google_adc"
           }

    assert provider.configured?
    refute provider.requires_api_key?
    assert provider.default_model == "google/gemini-2.5-flash"
  end

  test "selection validation returns typed missing config errors" do
    assert {:error, %Error{kind: :missing_config, provider: :openai}} =
             Registry.validate_selection("openai")

    assert {:error, %Error{kind: :invalid_config}} = Registry.validate_selection("ollama")
  end

  defp restore_config_path(nil), do: Application.delete_env(:beamcore, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:beamcore, :config_dets_path, path)

  defp google_adc_credentials_file do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_registry_google_adc_#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "type" => "authorized_user",
        "client_id" => "google-client",
        "client_secret" => "google-secret",
        "refresh_token" => "refresh-token",
        "token_uri" => "https://oauth2.googleapis.com/token"
      })
    )

    on_exit(fn -> File.rm(path) end)
    path
  end
end
