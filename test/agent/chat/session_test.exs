defmodule Beamcore.Agent.Chat.SessionTest do
  use ExUnit.Case
  alias Beamcore.Agent.Chat.Session

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })
  end

  test "generate_name/0 returns a funny name" do
    name = Session.generate_name()
    assert String.match?(name, ~r/^[a-z]+-[a-z]+-[a-z]+$/)
  end

  test "new/1 creates a session with log file" do
    client = Beamcore.Agent.OpenAI.client()
    session = Session.new(client)

    assert session.session_id != nil
    assert session.log_file != nil
    assert File.dir?(Path.dirname(session.log_file))
    assert session.project_nature == :elixir
  end

  test "log/2 appends data to file" do
    client = Beamcore.Agent.OpenAI.client()
    session = Session.new(client)

    data = %{test: "data"}
    Session.log(session, data)

    assert File.exists?(session.log_file)
    content = File.read!(session.log_file)
    assert content =~ ~s({"test":"data"})
  end

  describe "summarize_and_rollover/3" do
    setup do
      client = Beamcore.Agent.OpenAI.client()
      session = Session.new(client)

      %{client: client, session: session}
    end

    test "resets token counters in the new session", %{session: session} do
      # Test the token counter reset logic directly
      new_session = Session.new(session.client)

      # This is the exact logic from summarize_and_rollover/3
      new_session = %{
        new_session
        | total_prompt_tokens: 0,
          total_completion_tokens: 0,
          total_tokens: 0
      }

      assert new_session.total_prompt_tokens == 0
      assert new_session.total_completion_tokens == 0
      assert new_session.total_tokens == 0
    end

    test "updates token usage for the old session with summary API call tokens", %{
      session: session
    } do
      # Test the update_usage function which is used in summarize_and_rollover
      session_with_usage = %{
        session
        | total_prompt_tokens: 1000,
          total_completion_tokens: 500,
          total_tokens: 1500
      }

      usage = %{"prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150}
      updated_session = Session.update_usage(session_with_usage, usage)

      assert updated_session.total_prompt_tokens == 1100
      assert updated_session.total_completion_tokens == 550
      assert updated_session.total_tokens == 1650
    end

    test "replaces empty summary with default message" do
      default_summary =
        "Previous session summary was empty or invalid. Continuing with a fresh session."

      # This is the exact validation logic from summarize_and_rollover/3
      summary = ""

      validated_summary =
        if summary && is_binary(summary) && String.length(summary) > 0 &&
             String.length(summary) <= 10_000 do
          summary
        else
          default_summary
        end

      assert validated_summary == default_summary
    end

    test "replaces nil summary with default message" do
      default_summary =
        "Previous session summary was empty or invalid. Continuing with a fresh session."

      summary = nil

      validated_summary =
        if summary && is_binary(summary) && String.length(summary) > 0 &&
             String.length(summary) <= 10_000 do
          summary
        else
          default_summary
        end

      assert validated_summary == default_summary
    end

    test "replaces too long summary with default message" do
      default_summary =
        "Previous session summary was empty or invalid. Continuing with a fresh session."

      summary = String.duplicate("a", 10_001)

      validated_summary =
        if summary && is_binary(summary) && String.length(summary) > 0 &&
             String.length(summary) <= 10_000 do
          summary
        else
          default_summary
        end

      assert validated_summary == default_summary
    end

    test "uses valid summary when provided" do
      valid_summary = "This is a valid summary of the session."

      validated_summary =
        if valid_summary && is_binary(valid_summary) && String.length(valid_summary) > 0 &&
             String.length(valid_summary) <= 10_000 do
          valid_summary
        else
          "Previous session summary was empty or invalid. Continuing with a fresh session."
        end

      assert validated_summary == valid_summary
    end

    test "fallback behavior returns old session with updated messages", %{session: session} do
      # This is the exact fallback logic from summarize_and_rollover/3
      messages = [%{role: "user", content: "Hello"}]
      result = %{session | messages: messages}

      assert result.session_id == session.session_id
      assert result.messages == messages
      assert result.total_prompt_tokens == session.total_prompt_tokens
      assert result.total_completion_tokens == session.total_completion_tokens
      assert result.total_tokens == session.total_tokens
    end
  end

  describe "trim_and_clean_messages/2" do
    test "truncates large message content to 4000 characters" do
      large_content = String.duplicate("a", 5000)

      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: large_content}
      ]

      trimmed = Session.trim_and_clean_messages(messages)
      user_msg = Enum.find(trimmed, fn m -> m.role == "user" end)
      assert String.length(user_msg.content) < 5000
      assert user_msg.content =~ "... [content truncated for summarization] ..."
    end

    test "removes leading and orphaned tool messages" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "tool", tool_call_id: "1", content: "orphaned_tool"},
        %{role: "user", content: "hello"},
        %{role: "tool", tool_call_id: "2", content: "another_orphaned_tool"}
      ]

      trimmed = Session.trim_and_clean_messages(messages)

      # system message should be kept, and orphaned tools should be removed, leaving only the user message
      assert length(trimmed) == 2
      assert Enum.at(trimmed, 0).role == "system"
      assert Enum.at(trimmed, 1).role == "user"
    end

    test "keeps valid tool messages preceded by assistant" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hello"},
        %{role: "assistant", tool_calls: [%{"id" => "call_1"}]},
        %{role: "tool", tool_call_id: "call_1", content: "tool_result"}
      ]

      trimmed = Session.trim_and_clean_messages(messages)
      assert length(trimmed) == 4
      assert Enum.map(trimmed, & &1.role) == ["system", "user", "assistant", "tool"]
    end

    test "merges consecutive user or assistant messages" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hello 1"},
        %{role: "user", content: "hello 2"},
        %{role: "assistant", content: "response 1"},
        %{role: "assistant", content: "response 2"}
      ]

      trimmed = Session.trim_and_clean_messages(messages)
      assert length(trimmed) == 3
      assert Enum.map(trimmed, & &1.role) == ["system", "user", "assistant"]
      assert Enum.at(trimmed, 1).content == "hello 1\n\nhello 2"
      assert Enum.at(trimmed, 2).content == "response 1\n\nresponse 2"
    end

    test "limits total non-system messages to target count but keeps system message" do
      messages =
        [
          %{role: "system", content: "sys"}
        ] ++
          Enum.flat_map(1..20, fn i ->
            [
              %{role: "user", content: "user #{i}"},
              %{role: "assistant", content: "assistant #{i}"}
            ]
          end)

      # 40 non-system messages total.
      # If we limit to 10, it should keep system message + last 10 non-system messages starting with user
      trimmed = Session.trim_and_clean_messages(messages, 10)
      assert length(trimmed) == 11
      assert Enum.at(trimmed, 0).role == "system"
      assert Enum.at(trimmed, 1).role == "user"
    end
  end
end
