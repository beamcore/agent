defmodule Beamcore.Agent.Chat.APITest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias Beamcore.Agent.Chat.API

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })

    client = Beamcore.OpenAI.client()

    # Reset mock after each test
    on_exit(fn ->
      Process.delete(:mock_completions_create)
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

  test "execute/4 captures and prints debug info for OpenaiEx.Error with kind :bad_request", %{
    client: client
  } do
    error = %OpenaiEx.Error{
      kind: :bad_request,
      message: "Required parameter missing",
      status_code: 400,
      body: %{"error" => "Parameter 'prompt' is required"}
    }

    Process.put(:mock_completions_create, fn _client, _params ->
      {:error, error}
    end)

    output =
      capture_io(fn ->
        result = API.execute(client, [%{role: "user", content: "test query"}], [])
        assert {:error, _} = result
      end)

    assert output =~ "API BAD REQUEST ERROR DEBUG INFO"
    assert output =~ "ERROR DETAILS:"
    assert output =~ "API Bad Request (Likely out of context size limit)"
    assert output =~ "Parameter 'prompt' is required"
    assert output =~ "REQUEST DIAGNOSTICS:"
    assert output =~ "10 chars"
    assert output =~ "SEQUENCE VALIDATION:"
  end

  test "execute/4 captures and prints debug info for OpenaiEx.Error with status_code 400", %{
    client: client
  } do
    error = %OpenaiEx.Error{
      kind: :other_error,
      message: "Bad request error",
      status_code: 400,
      body: %{"error" => "Custom bad request details"}
    }

    Process.put(:mock_completions_create, fn _client, _params ->
      {:error, error}
    end)

    output =
      capture_io(fn ->
        result = API.execute(client, [%{role: "user", content: "another query"}], [])
        assert {:error, _} = result
      end)

    assert output =~ "API BAD REQUEST ERROR DEBUG INFO"
    assert output =~ "ERROR DETAILS:"
    assert output =~ "API Bad Request (Likely out of context size limit)"
    assert output =~ "Custom bad request details"
    assert output =~ "13 chars"
  end

  test "execute/4 captures and prints debug info for binary bad_request error", %{client: client} do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:error, "API error: bad_request (status_code: 400)"}
    end)

    output =
      capture_io(fn ->
        result = API.execute(client, [%{role: "user", content: "third query"}], [])
        assert {:error, _} = result
      end)

    assert output =~ "API BAD REQUEST ERROR DEBUG INFO"
    assert output =~ "ERROR DETAILS:"
    assert output =~ "bad_request (status_code: 400)"
    assert output =~ "11 chars"
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
      assert params.model == "mistral-small-2603"
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}]}}
    end)

    assert {:ok, %{message: %{"content" => "Hello"}}} =
             API.execute(client, [%{role: "user", content: "hello"}], [], :main,
               model: "mistral-small-2603"
             )
  end
end
