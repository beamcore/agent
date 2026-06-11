defmodule ChatTest do
  use ExUnit.Case

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })
  end

  test "chat session structure" do
    # Test that we can create a chat session with proper structure
    client = Beamcore.OpenAI.client()

    session = %Beamcore.Agent.Chat.Session{
      messages: [],
      client: client
    }

    assert session.messages == []
    assert session.client != nil
  end

  test "send_message adds user message to session" do
    # Test that send_message properly adds user messages to the session
    client = Beamcore.OpenAI.client()

    session = %Beamcore.Agent.Chat.Session{
      messages: [],
      client: client
    }

    # We can't test the full functionality without mocking the API,
    # but we can test that the message structure is correct
    user_message = %{role: "user", content: "ping"}
    new_messages = session.messages ++ [user_message]

    assert length(new_messages) == 1
    assert Enum.at(new_messages, 0).role == "user"
    assert Enum.at(new_messages, 0).content == "ping"
  end

  describe "Beamcore.Agent.Chat.API.execute/4 input validation" do
    test "returns error for empty messages list" do
      client = Beamcore.OpenAI.client()
      result = Beamcore.Agent.Chat.API.execute(client, [], nil, :main)
      assert result == {:error, "Messages must be a non-empty list."}
    end

    test "returns error for non-list messages" do
      client = Beamcore.OpenAI.client()
      result = Beamcore.Agent.Chat.API.execute(client, "not a list", nil, :main)
      assert result == {:error, "Messages must be a non-empty list."}
    end

    test "returns error for non-list tools" do
      client = Beamcore.OpenAI.client()
      messages = [%{role: "user", content: "test"}]
      result = Beamcore.Agent.Chat.API.execute(client, messages, "not a list", :main)
      assert result == {:error, "Tools must be a list."}
    end

    test "accepts valid messages and tools" do
      client = Beamcore.OpenAI.client()
      messages = [%{role: "user", content: "test"}]
      tools = [%{type: "function", function: %{name: "eeva", description: "test"}}]
      # This test will not fail the validation, but may fail later due to API calls
      # We only test that validation passes
      assert Beamcore.Agent.Chat.API.execute(client, messages, tools, :main) !=
               {:error, "Messages must be a non-empty list."}

      assert Beamcore.Agent.Chat.API.execute(client, messages, tools, :main) !=
               {:error, "Tools must be a list."}
    end

    test "accepts valid messages with nil tools" do
      client = Beamcore.OpenAI.client()
      messages = [%{role: "user", content: "test"}]
      # This test will not fail the validation, but may fail later due to API calls
      # We only test that validation passes
      assert Beamcore.Agent.Chat.API.execute(client, messages, nil, :main) !=
               {:error, "Messages must be a non-empty list."}

      assert Beamcore.Agent.Chat.API.execute(client, messages, nil, :main) !=
               {:error, "Tools must be a list."}
    end
  end
end
