defmodule Beamcore.Provider.AuthTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.Auth
  alias Beamcore.Provider.Error

  setup do
    Auth.clear_cache()
    Process.put(:auth_test_pid, self())
    Process.delete(:auth_http_responses)

    on_exit(fn ->
      Auth.clear_cache()
      Process.delete(:auth_test_pid)
      Process.delete(:auth_http_responses)
    end)

    :ok
  end

  test "generates static API key headers" do
    assert {:ok, [{"Authorization", "Bearer static-key"}]} =
             Auth.headers(%{"auth" => "api_key", "api_key" => "static-key"})

    assert {:ok, [{"X-API-Key", "static-key"}]} =
             Auth.headers(%{
               "auth" => "api_key",
               "api_key" => "static-key",
               "api_key_header" => "X-API-Key",
               "api_key_prefix" => ""
             })
  end

  test "generates bearer token headers" do
    assert {:ok, %{headers: [{"Authorization", "Bearer bearer-token"}], token: "bearer-token"}} =
             Auth.material(%{"auth" => "bearer", "bearer_token" => "bearer-token"})
  end

  test "requests OAuth client credentials tokens" do
    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "token-a", "expires_in" => 3600}}}
    )

    config = %{
      "auth" => "oauth2",
      "token_url" => "https://auth.example/token",
      "client_id" => "client",
      "client_secret" => "secret",
      "scope" => "chat.read"
    }

    assert {:ok, [{"Authorization", "Bearer token-a"}]} =
             Auth.headers(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, "https://auth.example/token", opts}
    assert opts[:body] == "grant_type=client_credentials&scope=chat.read"

    assert {"Authorization", "Basic " <> _encoded} =
             List.keyfind(opts[:headers], "Authorization", 0)
  end

  test "caches OAuth tokens until the refresh window" do
    Process.put(:auth_http_responses, [
      {:ok, %{status: 200, body: %{"access_token" => "cached-token", "expires_in" => 3600}}},
      {:ok, %{status: 200, body: %{"access_token" => "unexpected", "expires_in" => 3600}}}
    ])

    config = oauth_config()

    assert {:ok, %{token: "cached-token"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert {:ok, %{token: "cached-token"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, _, _}
    refute_receive {:oauth_post, _, _}, 20
  end

  test "refreshes OAuth tokens after expiry" do
    Process.put(:auth_http_responses, [
      {:ok, %{status: 200, body: %{"access_token" => "expired-token", "expires_in" => 0}}},
      {:ok, %{status: 200, body: %{"access_token" => "fresh-token", "expires_in" => 3600}}}
    ])

    config = oauth_config()

    assert {:ok, %{token: "expired-token"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert {:ok, %{token: "fresh-token"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)
  end

  test "returns clear errors when OAuth config is incomplete" do
    assert {:error, %Error{kind: :missing_config, message: message}} =
             Auth.validate_config(%{
               "auth" => "oauth2",
               "token_url" => "https://auth.example/token"
             })

    assert message =~ "client_id"
    refute message =~ "secret"
  end

  test "supports OAuth2 provider with scope and request id header" do
    Process.put(
      :auth_http_responses,
      {:ok,
       %{
         status: 200,
         body: %{
           "access_token" => "giga-token",
           "expires_at" => System.system_time(:millisecond) + 3_600_000
         }
       }}
    )

    config = %{
      "auth" => "oauth2",
      "token_url" => "https://auth.scoped-provider.example/oauth",
      "client_id" => "scoped-client",
      "client_secret" => "scoped-secret",
      "scope" => "CHAT_API_SCOPE",
      "token_request_id_header" => "RqUID"
    }

    assert {:ok, %{token: "giga-token"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, _, opts}
    assert opts[:body] =~ "scope=CHAT_API_SCOPE"
    assert {"RqUID", request_id} = List.keyfind(opts[:headers], "RqUID", 0)
    assert byte_size(request_id) == 32
  end

  defp oauth_config do
    %{
      "auth" => "oauth2",
      "token_url" => "https://auth.example/token",
      "client_id" => "client",
      "client_secret" => "secret"
    }
  end
end
