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

  test "accepts explicit OAuth client credentials strategy alias" do
    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "token-a", "expires_in" => 3600}}}
    )

    config = %{
      "auth" => %{"strategy" => "oauth2_client_credentials"},
      "token_url" => "https://auth.example/token",
      "client_id" => "client",
      "client_secret" => "secret"
    }

    assert :ok = Auth.validate_config(config)

    assert {:ok, [{"Authorization", "Bearer token-a"}]} =
             Auth.headers(config, http_client: Beamcore.Provider.AuthHTTPMock)
  end

  test "requests OAuth tokens with pre-encoded Basic credential from api key" do
    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "token-a", "expires_in" => 3600}}}
    )

    config = %{
      "auth" => "oauth2",
      "token_url" => "https://auth.example/token",
      "api_key" => "preencoded-basic-key",
      "scope" => "chat.read"
    }

    assert {:ok, [{"Authorization", "Bearer token-a"}]} =
             Auth.headers(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, "https://auth.example/token", opts}
    assert opts[:body] == "grant_type=client_credentials&scope=chat.read"
    assert {"Authorization", "Basic preencoded-basic-key"} in opts[:headers]
  end

  test "preserves explicit Basic prefix for OAuth pre-encoded credentials" do
    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "token-a", "expires_in" => 3600}}}
    )

    config = %{
      "auth" => "oauth2",
      "token_url" => "https://auth.example/token",
      "api_key" => "Basic preencoded-basic-key"
    }

    assert {:ok, %{token: "token-a"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, "https://auth.example/token", opts}
    assert {"Authorization", "Basic preencoded-basic-key"} in opts[:headers]
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

  test "google_adc does not require token_url client_id or client_secret" do
    credentials_path = google_adc_credentials_file()

    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "google-token", "expires_in" => 3600}}}
    )

    config = %{
      "auth" => %{
        "strategy" => "google_adc",
        "credentials_file" => credentials_path,
        "scope" => "https://www.googleapis.com/auth/cloud-platform"
      }
    }

    assert :ok = Auth.validate_config(config)

    assert {:ok, [{"Authorization", "Bearer google-token"}]} =
             Auth.headers(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, "https://oauth2.googleapis.com/token", opts}
    assert opts[:body] =~ "grant_type=refresh_token"
    assert opts[:body] =~ "refresh_token=refresh-token"
  end

  test "google_adc returns a clear error when credentials are missing" do
    config = %{
      "auth" => %{
        "strategy" => "google_adc",
        "credentials_file" => "/tmp/beamcore-missing-google-adc.json"
      }
    }

    assert {:error, %Error{kind: :missing_config, message: message}} =
             Auth.validate_config(config)

    assert message =~ "Google ADC credentials file was not found"
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

    assert request_id =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "supports provider-neutral OAuth token TLS options" do
    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "tls-token", "expires_in" => 3600}}}
    )

    config =
      oauth_config()
      |> Map.put("cacertfile", "/tmp/provider-ca.pem")
      |> Map.put("ssl_verify", false)

    assert {:ok, %{token: "tls-token"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, _, opts}

    assert opts[:connect_options] == [
             transport_opts: [cacertfile: "/tmp/provider-ca.pem", verify: :verify_none]
           ]
  end

  test "auto TLS mode retries OAuth token requests without verify on unknown CA" do
    Process.put(:auth_http_responses, [
      {:error,
       %Req.TransportError{
         reason:
           {:tls_alert, {:unknown_ca, ~c"TLS client generated CLIENT ALERT: Fatal - Unknown CA"}}
       }},
      {:ok, %{status: 200, body: %{"access_token" => "retried-token", "expires_in" => 3600}}}
    ])

    config = Map.put(oauth_config(), "ssl_verify", "auto")

    assert {:ok, %{token: "retried-token"}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, _, first_opts}
    assert_receive {:oauth_post, _, retry_opts}

    refute Keyword.has_key?(first_opts, :connect_options)
    assert retry_opts[:connect_options] == [transport_opts: [verify: :verify_none]]
  end

  test "strict TLS mode does not retry OAuth token unknown CA failures" do
    reason =
      %Req.TransportError{
        reason:
          {:tls_alert, {:unknown_ca, ~c"TLS client generated CLIENT ALERT: Fatal - Unknown CA"}}
      }

    Process.put(:auth_http_responses, [
      {:error, reason},
      {:ok, %{status: 200, body: %{"access_token" => "unexpected", "expires_in" => 3600}}}
    ])

    config = Map.put(oauth_config(), "ssl_verify", true)

    assert {:error, %Error{kind: :unavailable}} =
             Auth.material(config, http_client: Beamcore.Provider.AuthHTTPMock)

    assert_receive {:oauth_post, _, _}
    refute_receive {:oauth_post, _, _}, 20
  end

  defp oauth_config do
    %{
      "auth" => "oauth2",
      "token_url" => "https://auth.example/token",
      "client_id" => "client",
      "client_secret" => "secret"
    }
  end

  defp google_adc_credentials_file do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_google_adc_#{System.unique_integer([:positive])}.json"
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
