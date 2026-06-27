defmodule Beamcore.Provider.RouterTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.Router

  setup do
    path =
      Path.join(System.tmp_dir!(), "beamcore_router_#{System.unique_integer([:positive])}.dets")

    previous_path = Application.get_env(:beamcore, :config_dets_path)
    previous_auth_http_client = Application.get_env(:beamcore, :auth_http_client)
    previous_compatible_http_client = Application.get_env(:beamcore, :compatible_http_client)
    Application.put_env(:beamcore, :config_dets_path, path)
    Application.put_env(:beamcore, :auth_http_client, Beamcore.Provider.AuthHTTPMock)

    Beamcore.Config.put_provider("openai", %{
      api_key: "test-openai-key",
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o"
    })

    on_exit(fn ->
      restore_config_path(previous_path)
      restore_auth_http_client(previous_auth_http_client)
      restore_compatible_http_client(previous_compatible_http_client)
      File.rm(path)
      Process.delete(:mock_completions_create)
      Process.delete(:auth_test_pid)
      Process.delete(:compatible_test_pid)
      Process.delete(:auth_http_responses)
      Process.delete(:compatible_http_responses)
      Beamcore.Provider.Auth.clear_cache()
    end)

    Process.put(:auth_test_pid, self())
    Process.put(:compatible_test_pid, self())

    :ok
  end

  test "routes OpenAI chat through the registry-selected compatible adapter" do
    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "openai", model: "gpt-4o"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:call, "https://api.openai.com/v1", "test-openai-key", "gpt-4o"}
  end

  test "routes a custom compatible provider without adding an adapter module" do
    assert :ok =
             Beamcore.Config.put_provider("custom-compatible", %{
               api_key: "secret",
               base_url: "https://compatible.example/v1",
               default_model: "model-a"
             })

    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "custom-compatible", model: "model-a"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:call, "https://compatible.example/v1", "secret", "model-a"}
  end

  test "OpenAI-compatible params preserve message order by default" do
    assert {:ok, params} =
             Beamcore.Provider.Adapters.OpenAICompatible.params(%{
               model: "model-a",
               tools: [],
               messages: [
                 %{role: "user", content: "hi"},
                 %{role: "system", content: "system one"},
                 %{"role" => "assistant", "content" => "hello"},
                 %{"role" => "system", "content" => "system two"}
               ]
             })

    assert Enum.map(params.messages, fn
             %{role: role} -> role
             %{"role" => role} -> role
           end) == ["user", "system", "assistant", "system"]

    assert Enum.map(params.messages, fn
             %{content: content} -> content
             %{"content" => content} -> content
           end) == ["hi", "system one", "hello", "system two"]
  end

  test "routes OpenAI-compatible provider with OAuth2 auth" do
    assert :ok =
             Beamcore.Config.put_provider("oauth-compatible", %{
               auth: :oauth2,
               token_url: "https://auth.example/token",
               client_id: "client",
               client_secret: "secret",
               scope: "CHAT_API_SCOPE",
               token_request_id_header: "RqUID",
               base_url: "https://oauth-compatible.example/v1",
               default_model: "chat-model"
             })

    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "oauth-chat-token", "expires_in" => 3600}}}
    )

    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, client._http_headers, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "oauth-compatible", model: "chat-model"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:call, "https://oauth-compatible.example/v1", "oauth-chat-token", headers,
                    "chat-model"}

    assert {"Authorization", "Bearer oauth-chat-token"} in headers
    assert_receive {:oauth_post, "https://auth.example/token", opts}
    assert {"RqUID", _request_id} = List.keyfind(opts[:headers], "RqUID", 0)
  end

  test "routes Gemini Vertex OpenAI-compatible provider with Google ADC auth" do
    Application.put_env(:beamcore, :compatible_http_client, Beamcore.Provider.CompatibleHTTPMock)

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

    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "google-chat-token", "expires_in" => 3600}}}
    )

    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, client._http_headers, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "google-vertex", model: "google/gemini-2.5-flash"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:oauth_post, "https://oauth2.googleapis.com/token", auth_opts}
    assert auth_opts[:body] =~ "grant_type=refresh_token"
    assert auth_opts[:body] =~ "refresh_token=refresh-token"

    assert_receive {:call,
                    "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1/endpoints/openapi",
                    "google-chat-token", headers, "google/gemini-2.5-flash"}

    assert {"Authorization", "Bearer google-chat-token"} in headers
  end

  test "OAuth2 compatible providers send system messages before conversation messages" do
    Application.put_env(:beamcore, :compatible_http_client, Beamcore.Provider.CompatibleHTTPMock)

    assert :ok =
             Beamcore.Config.put_provider("oauth-order-compatible", %{
               auth: :oauth2,
               token_url: "https://auth.example/token",
               api_key: "preencoded-basic-key",
               base_url: "https://oauth-order-compatible.example/v1",
               default_model: "chat-model",
               ssl_verify: "auto"
             })

    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "oauth-chat-token", "expires_in" => 3600}}}
    )

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "oauth-order-compatible", model: "chat-model"},
               %{
                 tools: [],
                 messages: [
                   %{role: "user", content: "hi"},
                   %{role: "system", content: "system one"},
                   %{"role" => "assistant", "content" => "hello"},
                   %{"role" => "system", "content" => "system two"}
                 ]
               }
             )

    assert_receive {:compatible_post, _, opts}

    assert Enum.map(opts[:json].messages, fn
             %{role: role} -> role
             %{"role" => role} -> role
           end) == ["system", "user", "assistant"]

    assert Enum.map(opts[:json].messages, fn
             %{content: content} -> content
             %{"content" => content} -> content
           end) == ["system one\n\nsystem two", "hi", "hello"]
  end

  test "routes OpenAI-compatible provider with provider TLS options through Req path" do
    Application.put_env(:beamcore, :compatible_http_client, Beamcore.Provider.CompatibleHTTPMock)

    assert :ok =
             Beamcore.Config.put_provider("tls-compatible", %{
               auth: :oauth2,
               token_url: "https://auth.example/token",
               client_id: "client",
               client_secret: "secret",
               scope: "CHAT_API_SCOPE",
               token_request_id_header: "RqUID",
               base_url: "https://tls-compatible.example/v1",
               default_model: "chat-model",
               cacertfile: "/tmp/provider-ca.pem"
             })

    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "oauth-chat-token", "expires_in" => 3600}}}
    )

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "tls-compatible", model: "chat-model"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:oauth_post, "https://auth.example/token", auth_opts}

    assert auth_opts[:connect_options] == [
             transport_opts: [cacertfile: "/tmp/provider-ca.pem"]
           ]

    assert_receive {:compatible_post, "https://tls-compatible.example/v1/chat/completions",
                    chat_opts}

    assert chat_opts[:connect_options] == [
             transport_opts: [cacertfile: "/tmp/provider-ca.pem"]
           ]

    assert {"Authorization", "Bearer oauth-chat-token"} in chat_opts[:headers]
  end

  test "auto TLS mode retries compatible chat request without verify on unknown CA" do
    Application.put_env(:beamcore, :compatible_http_client, Beamcore.Provider.CompatibleHTTPMock)

    assert :ok =
             Beamcore.Config.put_provider("auto-tls-compatible", %{
               auth: :oauth2,
               token_url: "https://auth.example/token",
               client_id: "client",
               client_secret: "secret",
               base_url: "https://auto-tls-compatible.example/v1",
               default_model: "chat-model",
               ssl_verify: "auto"
             })

    Process.put(
      :auth_http_responses,
      {:ok, %{status: 200, body: %{"access_token" => "oauth-chat-token", "expires_in" => 3600}}}
    )

    Process.put(:compatible_http_responses, [
      {:error,
       %Req.TransportError{
         reason:
           {:tls_alert, {:unknown_ca, ~c"TLS client generated CLIENT ALERT: Fatal - Unknown CA"}}
       }},
      {:ok,
       %{
         status: 200,
         body: %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}
       }}
    ])

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "auto-tls-compatible", model: "chat-model"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:compatible_post, _, first_opts}
    assert_receive {:compatible_post, _, retry_opts}

    refute Keyword.has_key?(first_opts, :connect_options)
    assert retry_opts[:connect_options] == [transport_opts: [verify: :verify_none]]
  end

  test "returns typed error for unsupported provider selection" do
    assert {:error, %Beamcore.Provider.Error{kind: :invalid_config}} =
             Router.chat(
               %{provider: "missing-provider", model: "model"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )
  end

  test "router does not contain provider-brand adapter mappings" do
    source = File.read!(Path.expand("../../../lib/beamcore/provider/router.ex", __DIR__))

    refute source =~ "@adapters"
    refute source =~ ~s("ollama" =>)
    refute source =~ "Beamcore.Provider.Mistral"
    refute source =~ "Beamcore.Provider.Ollama"
    refute source =~ "Beamcore.Provider.Generic"
  end

  test "OpenAI-compatible adapter does not hardcode provider identity maps" do
    source =
      File.read!(
        Path.expand(
          "../../../lib/beamcore/provider/adapters/openai_compatible.ex",
          __DIR__
        )
      )

    refute source =~ "provider_atom"
    refute source =~ ~s("ollama")
    refute source =~ ~s("openai")
    refute source =~ ~s("deepseek")
  end

  defp restore_config_path(nil), do: Application.delete_env(:beamcore, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:beamcore, :config_dets_path, path)

  defp restore_auth_http_client(nil), do: Application.delete_env(:beamcore, :auth_http_client)

  defp restore_auth_http_client(module),
    do: Application.put_env(:beamcore, :auth_http_client, module)

  defp restore_compatible_http_client(nil),
    do: Application.delete_env(:beamcore, :compatible_http_client)

  defp restore_compatible_http_client(module),
    do: Application.put_env(:beamcore, :compatible_http_client, module)

  defp google_adc_credentials_file do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_router_google_adc_#{System.unique_integer([:positive])}.json"
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
