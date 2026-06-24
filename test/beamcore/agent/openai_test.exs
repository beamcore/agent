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
    previous_auth_http_client = Application.get_env(:beamcore, :auth_http_client)
    Application.put_env(:beamcore, :config_dets_path, path)
    Application.put_env(:beamcore, :auth_http_client, Beamcore.Provider.AuthHTTPMock)

    on_exit(fn ->
      restore_config_path(previous)
      restore_auth_http_client(previous_auth_http_client)
      Beamcore.Provider.Auth.clear_cache()
      Process.delete(:auth_test_pid)
      Process.delete(:auth_http_responses)
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

  test "client/0 builds a client from OAuth provider config" do
    Process.put(:auth_test_pid, self())

    Process.put(
      :auth_http_responses,
      {:ok,
       %{status: 200, body: %{"access_token" => "registry-oauth-token", "expires_in" => 3600}}}
    )

    Beamcore.Config.put_provider("oauth-compatible", %{
      auth: :oauth2,
      token_url: "https://auth.example/token",
      client_id: "client",
      client_secret: "secret",
      base_url: "https://compatible.example/v1",
      default_model: "model-a"
    })

    Beamcore.Config.set_active_provider("oauth-compatible")

    client = Registry.client()

    assert client.token == "registry-oauth-token"
    assert client.base_url == "https://compatible.example/v1"
    assert {"Authorization", "Bearer registry-oauth-token"} in client._http_headers
  end

  defp restore_config_path(nil), do: Application.delete_env(:beamcore, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:beamcore, :config_dets_path, path)

  defp restore_auth_http_client(nil), do: Application.delete_env(:beamcore, :auth_http_client)

  defp restore_auth_http_client(module),
    do: Application.put_env(:beamcore, :auth_http_client, module)
end
