defmodule Beamcore.Agent.Chat.LocalTimeoutTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.{Loop, Session}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "BEAMCORE_RESEARCH_PROVIDER" => "ollama",
      "BEAMCORE_RESEARCH_MODEL" => "gemma4:latest",
      "BEAMCORE_CHAT_PROVIDER" => "ollama",
      "BEAMCORE_CHAT_MODEL" => "gemma4:latest",
      "BEAMCORE_SEARCH_CONDUCTOR" => "false",
      "BEAMCORE_LOCAL_PROVIDER_RECEIVE_TIMEOUT_MS" => nil
    })

    on_exit(fn ->
      Process.delete(:mock_completions_create)
      Process.delete(:mock_completions_calls)
    end)

    :ok
  end

  test "resolved F3 provider and model reach the provider client" do
    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:provider_call, client.base_url, client.receive_timeout, params.model})

      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => "ok"}}
         ],
         "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
       }}
    end)

    session = Session.new(nil, screen_type: :research)

    result =
      Loop.send_message(session, "Inspect architecture. Do not modify files.", nil, nil,
        silent: true
      )

    assert_receive {:provider_call, "http://127.0.0.1:11434/v1", 120_000, "gemma4:latest"}
    assert Enum.any?(result.timeline, &(&1.type == :completed))
  end

  test "minimal Ollama-compatible response completes normally" do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "OK"}}]}}
    end)

    session = Session.new(nil, screen_type: :research)

    result = Loop.send_message(session, "Say OK.", nil, nil, silent: true)

    assert Enum.any?(result.timeline, &(&1.type == :completed))
    refute Enum.any?(result.timeline, &(&1.type == :failed))
  end

  test "local provider timeout is classified with role provider model and is not retried" do
    Process.put(:mock_completions_calls, 0)

    Process.put(:mock_completions_create, fn _client, _params ->
      Process.put(:mock_completions_calls, Process.get(:mock_completions_calls, 0) + 1)
      {:error, %OpenaiEx.Error{kind: :api_timeout_error, message: "Request timed out."}}
    end)

    session = Session.new(nil, screen_type: :research)

    result = Loop.send_message(session, "Inspect architecture.", nil, nil, silent: true)

    assert Process.get(:mock_completions_calls) == 1

    timeout_event = Enum.find(result.timeline, &(&1.type == :failed))
    assert timeout_event.role == :synthesizer
    assert timeout_event.summary =~ "Synthesizer timed out"
    assert timeout_event.summary =~ "Provider: ollama"
    assert timeout_event.summary =~ "Model: gemma4:latest"
    assert timeout_event.metadata.timeout_type == :non_streaming_receive_timeout
    assert timeout_event.metadata.configured_duration_ms == 120_000
    assert timeout_event.metadata.max_attempts == 1
    assert timeout_event.metadata.stream == false
  end

  test "F2 does not invoke Deep Research stages" do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "chat"}}]}}
    end)

    session = Session.new(nil, screen_type: :chat)
    result = Loop.send_message(session, "Hello.", nil, nil, silent: true)

    refute Enum.any?(result.timeline, &(&1.type == :research_stage))
  end

  test "F3 model call is role-specific, not generic primary text" do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    session = Session.new(nil, screen_type: :research)
    result = Loop.send_message(session, "Inspect architecture.", nil, nil, silent: true)

    model_call = Enum.find(result.timeline, &(&1.type == :model_call))

    assert model_call.role == :synthesizer
    assert model_call.title == "Synthesizer model call"
    assert model_call.summary =~ "Synthesizer called ollama/gemma4:latest"
    refute model_call.summary =~ "Calling primary model"
  end

  test "F3 creates one researcher stage before the first provider call" do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:error, %OpenaiEx.Error{kind: :api_timeout_error, message: "Request timed out."}}
    end)

    session = Session.new(nil, screen_type: :research)
    result = Loop.send_message(session, "Inspect architecture.", nil, nil, silent: true)

    researcher_events =
      Enum.filter(result.timeline, &(&1.type == :research_stage and &1.role == :researcher))

    assert length(researcher_events) == 1
  end
end
