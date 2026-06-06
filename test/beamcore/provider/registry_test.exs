defmodule Beamcore.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.{Capabilities, Error, Registry}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_provider_registry_#{System.unique_integer([:positive])}.dets"
      )

    previous_path = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => nil,
      "API_KEY" => nil,
      "ACTIVE_PROVIDER" => nil
    })

    on_exit(fn ->
      restore_config_path(previous_path)
      File.rm(path)
    end)

    :ok
  end

  test "lists default providers with provider-neutral capabilities" do
    providers = Registry.list()

    assert Enum.any?(providers, &(&1.name == "mistral"))

    ollama = Enum.find(providers, &(&1.name == "ollama"))
    assert ollama.configured?
    assert ollama.requires_api_key? == false
    assert ollama.adapter == Beamcore.Provider.Adapters.OpenAICompatible
    assert ollama.discovery == Beamcore.Provider.OllamaDiscovery
    assert %Capabilities{local: true, chat: true} = ollama.capabilities

    mistral = Enum.find(providers, &(&1.name == "mistral"))
    assert mistral.requires_api_key?
    assert mistral.adapter == Beamcore.Provider.Adapters.OpenAICompatible
    assert %Capabilities{tool_calls: true, local: false} = mistral.capabilities
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

  test "selection validation returns typed missing config errors" do
    assert {:error, %Error{kind: :missing_config, provider: :mistral}} =
             Registry.validate_selection("mistral")

    assert {:ok, %{name: "ollama"}} = Registry.validate_selection("ollama")
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end
