defmodule Beamcore.Provider.ModelMetadataTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.{Health, ModelMetadata}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_model_metadata_#{System.unique_integer([:positive])}.dets"
      )

    previous_path = Application.get_env(:agent, :config_dets_path)
    previous_http = Application.get_env(:agent, :global_mock_http_request)
    Application.put_env(:agent, :config_dets_path, path)

    Beamcore.Agent.TestEnv.setup_env(%{
      "OPENAI_API_KEY" => nil,
      "API_KEY" => nil,
      "ACTIVE_PROVIDER" => nil
    })

    Health.invalidate(:all)

    on_exit(fn ->
      restore_config_path(previous_path)
      restore_http(previous_http)
      Health.invalidate(:all)
      File.rm(path)
    end)

    :ok
  end

  test "registry fallback is marked as estimated when API does not provide context" do
    metadata = ModelMetadata.fallback("openai", "gpt-4o")

    assert metadata.context_window == 128_000
    assert metadata.source == :registry
    assert metadata.accuracy == :estimated
  end

  test "unknown context remains explicit for unconfigured custom providers" do
    assert :ok =
             Beamcore.Config.put_provider("custom-compatible", %{
               api_key: "secret",
               base_url: "https://example.test/v1",
               default_model: "model-a"
             })

    metadata = ModelMetadata.fallback("custom-compatible", "model-a")

    assert metadata.context_window == nil
    assert metadata.source == :unknown
    assert metadata.accuracy == :unknown
  end

  test "custom provider can define model context metadata via config" do
    assert :ok =
             Beamcore.Config.put_provider("custom-compatible", %{
               api_key: "secret",
               base_url: "https://example.test/v1",
               default_model: "model-a",
               context_window: 12_000,
               max_output_tokens: 1_500,
               tokenizer: "custom-bpe"
             })

    metadata = ModelMetadata.fallback("custom-compatible", "model-a")

    assert metadata.context_window == 12_000
    assert metadata.max_output_tokens == 1_500
    assert metadata.tokenizer == "custom-bpe"
    assert metadata.source == :config
    assert metadata.accuracy == :reported
    refute inspect(metadata) =~ "secret"
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)

  defp restore_http(nil), do: Application.delete_env(:agent, :global_mock_http_request)
  defp restore_http(fun), do: Application.put_env(:agent, :global_mock_http_request, fun)
end
