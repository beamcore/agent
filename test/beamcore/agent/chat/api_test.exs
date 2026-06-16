defmodule Beamcore.Agent.Chat.APITest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias Beamcore.Agent.Chat.API
  alias Beamcore.Retry.Config

  setup do
    Beamcore.Config.put_provider("openai", %{
      api_key: "test-api-key",
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o"
    })

    Beamcore.Config.set_active_provider("openai")

    client = Beamcore.Provider.Registry.client()

    # Reset mock after each test
    on_exit(fn ->
      Process.delete(:mock_completions_create)
      Process.delete(:mock_completions_calls)
    end)

    %{client: client}
  end

  test "execute/4 returns success response", %{client: client} do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}]}}
    end)

    assert {:ok, %{message: %{"content" => "Hello"}}} =
             API.execute(client, [%{role: "user", content: "hello"}], [])
  end

  test "execute/4 does not print debug info for other errors", %{client: client} do
    error = %OpenaiEx.Error{
      kind: :forbidden,
      message: "Forbidden",
      status_code: 403
    }

    Process.put(:mock_completions_create, fn _client, _params ->
      {:error, error}
    end)

    output =
      capture_io(fn ->
        result = API.execute(client, [%{role: "user", content: "query for 403"}], [])
        assert {:error, _} = result
      end)

    refute output =~ "API BAD REQUEST ERROR DEBUG INFO"
  end

  test "execute/5 supports custom model in opts", %{client: client} do
    Process.put(:mock_completions_create, fn _client, params ->
      assert params.model == "gpt-4o-mini"
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}]}}
    end)

    assert {:ok, %{message: %{"content" => "Hello"}}} =
             API.execute(client, [%{role: "user", content: "hello"}], [], model: "gpt-4o-mini")
  end

  test "execute/5 uses Retry-After delay for provider rate limit", %{client: client} do
    parent = self()

    error = %OpenaiEx.Error{
      kind: :rate_limit,
      status_code: 429,
      body: %{"retry_after" => "7"}
    }

    Process.put(:mock_completions_calls, 0)

    Process.put(:mock_completions_create, fn _client, _params ->
      Process.put(:mock_completions_calls, Process.get(:mock_completions_calls, 0) + 1)
      {:error, error}
    end)

    retry_config = retry_config(fn ms -> send(parent, {:sleep, ms}) end)

    assert {:error, ^error} =
             API.execute(client, [%{role: "user", content: "hello"}], [],
               retry_config: retry_config
             )

    assert_receive {:sleep, 7000}
    assert Process.get(:mock_completions_calls) == 2
  end

  test "execute/5 uses fallback backoff for provider rate limit without Retry-After", %{
    client: client
  } do
    parent = self()
    error = %OpenaiEx.Error{kind: :rate_limit, status_code: 429}

    Process.put(:mock_completions_create, fn _client, _params ->
      {:error, error}
    end)

    retry_config = retry_config(fn ms -> send(parent, {:sleep, ms}) end)

    assert {:error, ^error} =
             API.execute(client, [%{role: "user", content: "hello"}], [],
               retry_config: retry_config
             )

    assert_receive {:sleep, 5000}
  end

  test "execute/5 passes requested max_tokens through provider selection" do
    assert :ok =
             Beamcore.Config.put_provider("custom-compatible", %{
               api_key: "secret",
               base_url: "https://compatible.example/v1",
               default_model: "model-a"
             })

    parent = self()

    Process.put(:mock_completions_create, fn _client, params ->
      send(parent, {:params, params})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{message: %{"content" => "ok"}}} =
             API.execute(
               nil,
               [%{role: "user", content: "hi"}],
               [],
               selection: %{provider: "custom-compatible", model: "model-a"},
               model: "model-a",
               max_tokens: 321,
               silent: true
             )

    assert_receive {:params, %{max_tokens: 321}}
  end

  defp retry_config(sleep_fun) do
    %Config{
      max_retries: 1,
      initial_backoff: 5000,
      max_backoff: 15_000,
      backoff_multiplier: 1,
      retryable_errors: [:rate_limit],
      sleep_fun: sleep_fun
    }
  end
end
