defmodule Beamcore.Provider.RegistryClientTest do
  use ExUnit.Case

  alias Beamcore.Provider.Registry

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_registry_client_config_#{System.unique_integer([:positive])}.dets"
      )

    previous = Application.get_env(:beamcore, :config_dets_path)
    Application.put_env(:beamcore, :config_dets_path, path)

    on_exit(fn ->
      restore_config_path(previous)
      File.rm(path)
    end)

    %{config_path: path}
  end

  test "client/0 requires an API key for the active provider" do
    Beamcore.Config.set_active_provider("openai")
    assert_raise RuntimeError, ~r/not configured/, fn -> Registry.client() end
  end

  test "client/0 builds a client from stored config token" do
    Beamcore.Config.put_provider("openai", %{api_key: "stored-token"})
    Beamcore.Config.set_active_provider("openai")

    client = Registry.client()

    assert client.token == "stored-token"
    assert client.base_url == "https://api.openai.com/v1"
  end

  defp restore_config_path(nil), do: Application.delete_env(:beamcore, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:beamcore, :config_dets_path, path)
end
