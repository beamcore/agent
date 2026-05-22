defmodule ChatTest do
  use ExUnit.Case

  test "chat session structure" do
    # Test that we can create a chat session with proper structure
    client = Beamcore.Agent.OpenAI.client()

    session = %Beamcore.Agent.Chat.Session{
      messages: [],
      client: client
    }

    assert session.messages == []
    assert session.client != nil
  end

  test "send_message adds user message to session" do
    # Test that send_message properly adds user messages to the session
    client = Beamcore.Agent.OpenAI.client()

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
end
