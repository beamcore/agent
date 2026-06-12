defmodule Beamcore.Provider.RegistryClientTest do
  use ExUnit.Case

  alias Beamcore.Provider.Registry
  alias Beamcore.Agent.TestEnv

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_registry_client_config_#{System.unique_integer([:positive])}.dets"
      )

    previous = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    on_exit(fn ->
      restore_config_path(previous)
      File.rm(path)
    end)

    %{config_path: path}
  end

  test "client/0 requires an API key for the active provider" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => nil, "API_KEY" => nil}, fn ->
      assert_raise RuntimeError, ~r/not configured/, fn -> Registry.client() end
    end)
  end

  test "client/0 treats a blank MISTRAL_API_KEY as missing" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "   ", "API_KEY" => nil}, fn ->
      assert_raise RuntimeError, ~r/not configured/, fn -> Registry.client() end
    end)
  end

  test "client/0 builds a client from env token" do
    TestEnv.with_env(
      %{"MISTRAL_API_KEY" => "test-api-key", "API_KEY" => nil, "MISTRAL_BASE_URL" => nil},
      fn ->
        client = Registry.client()

        assert client.token == "test-api-key"
        assert client.base_url == "https://api.mistral.ai/v1"
      end
    )
  end

  test "client/0 uses stored config token when OS env is missing" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => nil, "API_KEY" => nil}, fn ->
      assert :ok = Beamcore.Config.put_mistral_api_key("stored-token")
      assert Registry.client().token == "stored-token"
    end)
  end

  test "client/0 env token wins over stored config token" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "env-token", "API_KEY" => nil}, fn ->
      assert :ok = Beamcore.Config.put_mistral_api_key("stored-token")
      assert Registry.client().token == "env-token"
    end)
  end

  test "env_api_key_present?/0 returns false when no env key is set" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => nil, "API_KEY" => nil}, fn ->
      refute Registry.env_api_key_present?()
    end)
  end

  test "env_api_key_present?/0 returns true when env key is set" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "some-token"}, fn ->
      assert Registry.env_api_key_present?()
    end)
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end
