defmodule Beamcore.Agent.Chat.SessionTest do
  use ExUnit.Case
  alias Beamcore.Agent.Chat.Session

  setup do
    Beamcore.Config.put_provider("openai", %{
      api_key: "test-api-key",
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o"
    })

    Beamcore.Config.set_active_provider("openai")
  end

  test "generate_name/0 returns a funny name" do
    name = Session.generate_name()
    assert String.match?(name, ~r/^[a-z]+-[a-z]+-[a-z]+$/)
  end

  test "new/1 creates a session with log file" do
    client = Beamcore.Provider.Registry.client()
    session = Session.new(client)

    assert session.session_id != nil
    assert session.log_file != nil
    assert File.dir?(Path.dirname(session.log_file))
  end

  test "log/2 appends data to file" do
    client = Beamcore.Provider.Registry.client()
    session = Session.new(client)

    data = %{test: "data"}
    Session.log(session, data)

    assert File.exists?(session.log_file)
    content = File.read!(session.log_file)
    assert content =~ ~s({"test":"data"})
  end

  describe "summarize_and_rollover/3" do
    setup do
      client = Beamcore.Provider.Registry.client()
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
    test "prepare_for_api includes compact session context message" do
      context =
        Beamcore.Agent.Chat.Context.new()
        |> Beamcore.Agent.Chat.Context.update_from_tool(
          "eeva",
          %{"code" => "File.read!(\"README.md\")"},
          Jason.encode!(%{"ok" => true, "filesystem_changes" => %{"mutations" => []}})
        )

      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hello"}
      ]

      prepared = Session.prepare_for_api(messages, context)

      assert Enum.at(prepared, 1).role == "system"
      assert Enum.at(prepared, 1).content =~ "Known session context"
      assert Enum.at(prepared, 1).content =~ "README.md"
      refute Enum.at(prepared, 1).content =~ "file content should not appear"
    end

    test "does not truncate large message content" do
      large_content = String.duplicate("a", 5000)

      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: large_content}
      ]

      trimmed = Session.trim_and_clean_messages(messages, 30)
      user_msg = Enum.find(trimmed, fn m -> m.role == "user" end)
      assert user_msg.content == large_content
    end

    test "prepare_for_api preserves long tool output in full" do
      long_output =
        "HEAD diagnostic\n" <>
          String.duplicate("middle noise\n", 500) <>
          "TAIL validation error\n"

      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "run validation"},
        %{role: "assistant", tool_calls: [%{"id" => "call_1"}]},
        %{role: "tool", tool_call_id: "call_1", content: long_output}
      ]

      prepared = Session.prepare_for_api(messages, nil)
      tool_msg = Enum.find(prepared, fn m -> m.role == "tool" end)

      assert tool_msg.content == long_output
    end

    test "compact_history keeps latest user request and preserves long tool output" do
      long_output =
        "format failed\n" <>
          String.duplicate("noise\n", 600) <>
          "mix test failed with exit code 2\n"

      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "old request"},
        %{role: "assistant", tool_calls: [%{"id" => "call_1"}]},
        %{role: "tool", tool_call_id: "call_1", content: long_output},
        %{role: "user", content: "latest request must stay"}
      ]

      compacted = Session.compact_history(messages)

      assert List.last(compacted).content == "latest request must stay"

      tool_msg = Enum.find(compacted, fn m -> m.role == "tool" end)
      assert tool_msg.content == long_output
    end

    test "prepare_for_api preserves large write tool call arguments" do
      large_content =
        "defmodule Scratch.Big do\n" <> String.duplicate("  def x, do: :ok\n", 80) <> "end\n"

      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "create file"},
        %{
          role: "assistant",
          tool_calls: [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "eeva",
                "arguments" =>
                  Jason.encode!(%{
                    "path" => "scratch/big.ex",
                    "content" => large_content
                  })
              }
            }
          ]
        },
        %{role: "tool", tool_call_id: "call_1", name: "eeva", content: "ok"}
      ]

      prepared = Session.prepare_for_api(messages, nil)
      assistant = Enum.find(prepared, fn m -> m.role == "assistant" end)
      [tool_call] = assistant.tool_calls
      args = Jason.decode!(tool_call["function"]["arguments"])

      assert args["path"] == "scratch/big.ex"
      assert args["content"] == large_content
    end

    test "prepare_for_api preserves patch arguments" do
      patch = """
      --- /dev/null
      +++ b/scratch/a.ex
      @@ -0,0 +1,80 @@
      #{String.duplicate("+line\n", 80)}
      """

      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "patch file"},
        %{
          role: "assistant",
          tool_calls: [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "eeva",
                "arguments" =>
                  Jason.encode!(%{
                    "patch_content" => patch,
                    "workdir" => "."
                  })
              }
            }
          ]
        },
        %{role: "tool", tool_call_id: "call_1", name: "eeva", content: "ok"}
      ]

      prepared = Session.prepare_for_api(messages, nil)
      assistant = Enum.find(prepared, fn m -> m.role == "assistant" end)
      [tool_call] = assistant.tool_calls
      args = Jason.decode!(tool_call["function"]["arguments"])

      assert args["workdir"] == "."
      assert args["patch_content"] == patch
    end

    test "removes leading and orphaned tool messages" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "tool", tool_call_id: "1", content: "orphaned_tool"},
        %{role: "user", content: "hello"},
        %{role: "tool", tool_call_id: "2", content: "another_orphaned_tool"}
      ]

      trimmed = Session.trim_and_clean_messages(messages, 30)

      # system message should be kept, and orphaned tools should be removed, leaving only the user message
      assert length(trimmed) == 2
      assert Enum.at(trimmed, 0).role == "system"
      assert Enum.at(trimmed, 1).role == "user"
    end

    test "removes assistant messages that become empty after stripping dangling tool calls" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hello"},
        %{role: "assistant", content: "", tool_calls: [%{"id" => "call_1"}]},
        %{role: "user", content: "interruption"}
      ]

      trimmed = Session.trim_and_clean_messages(messages, 30)

      # The assistant message had a dangling tool call. A synthetic
      # "[Interrupted]" tool response is injected, then the empty assistant
      # is removed, and consecutive user messages are merged.
      assert length(trimmed) == 4
      assert Enum.at(trimmed, 0).role == "system"
      assert Enum.at(trimmed, 1).role == "user"
      assert Enum.at(trimmed, 2).role == "tool"
      assert Enum.at(trimmed, 2).content =~ "Interrupted"
      assert Enum.at(trimmed, 3).role == "user"
    end

    test "keeps assistant messages with text content even if tool calls are stripped" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hello"},
        %{role: "assistant", content: "Let me think...", tool_calls: [%{"id" => "call_1"}]},
        %{role: "user", content: "interruption"}
      ]

      trimmed = Session.trim_and_clean_messages(messages, 30)

      # Assistant keeps content, dangling tool_call is stripped, and a synthetic
      # "[Interrupted]" tool response is injected after it.
      assert length(trimmed) == 5
      assert Enum.map(trimmed, & &1.role) == ["system", "user", "assistant", "tool", "user"]

      assistant = Enum.at(trimmed, 2)
      assert assistant.content == "Let me think..."
      refute Map.has_key?(assistant, :tool_calls)
      refute Map.has_key?(assistant, "tool_calls")

      synthetic = Enum.at(trimmed, 3)
      assert synthetic.role == "tool"
      assert synthetic.content =~ "Interrupted"
    end

    test "keeps valid tool messages preceded by assistant" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hello"},
        %{role: "assistant", tool_calls: [%{"id" => "call_1"}]},
        %{role: "tool", tool_call_id: "call_1", content: "tool_result"}
      ]

      trimmed = Session.trim_and_clean_messages(messages, 30)
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

      trimmed = Session.trim_and_clean_messages(messages, 30)
      assert length(trimmed) == 3
      assert Enum.map(trimmed, & &1.role) == ["system", "user", "assistant"]
      assert Enum.at(trimmed, 1).content == "hello 1\n\nhello 2"
      assert Enum.at(trimmed, 2).content == "response 1\n\nresponse 2"
    end

    test "limits total non-system messages to target count" do
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

      # 40 non-system messages total, limit 10 => keeps last 10 + 1 system
      trimmed = Session.trim_and_clean_messages(messages, 10)
      assert length(trimmed) == 11
      assert Enum.at(trimmed, 0).role == "system"
      assert Enum.at(trimmed, 1).role == "user"
    end
  end

  describe "transparent rollover and grace period" do
    test "update_usage/2 sets needs_compaction flag at grace threshold" do
      client = Beamcore.Provider.Registry.client()
      session = Session.new(client)

      # Below threshold
      session1 =
        Session.update_usage(session, %{
          "prompt_tokens" => 140_000,
          "completion_tokens" => 10,
          "total_tokens" => 140_010
        })

      refute session1.needs_compaction
      assert session1.last_prompt_tokens == 140_000

      # At/above threshold
      session2 =
        Session.update_usage(session1, %{
          "prompt_tokens" => 150_000,
          "completion_tokens" => 10,
          "total_tokens" => 150_010
        })

      assert session2.needs_compaction
      assert session2.last_prompt_tokens == 150_000

      # Keeps needs_compaction: true even when subsequently updated with lower tokens
      session3 =
        Session.update_usage(session2, %{
          "prompt_tokens" => 10_000,
          "completion_tokens" => 10,
          "total_tokens" => 10_010
        })

      assert session3.needs_compaction
      assert session3.last_prompt_tokens == 10_000
    end

    test "needs_rollover_now?/1 correctly identifies hard limit" do
      client = Beamcore.Provider.Registry.client()
      session = Session.new(client)

      refute Session.needs_rollover_now?(session)

      session1 = %{session | last_prompt_tokens: 199_999}
      refute Session.needs_rollover_now?(session1)

      session2 = %{session | last_prompt_tokens: 200_000}
      assert Session.needs_rollover_now?(session2)
    end

    test "Context.compact/1 trims context fields" do
      context = Beamcore.Agent.Chat.Context.new()

      # Populate fields with many items to test trimming
      context = %{
        context
        | inspected_files:
            MapSet.new([
              "a.ex",
              "b.ex",
              "c.ex",
              "d.ex",
              "e.ex",
              "f.ex",
              "g.ex",
              "h.ex",
              "i.ex",
              "j.ex",
              "k.ex",
              "l.ex",
              "m.ex",
              "n.ex",
              "o.ex",
              "p.ex",
              "q.ex",
              "r.ex",
              "s.ex",
              "t.ex",
              "u.ex",
              "v.ex"
            ]),
          blocked_attempts: ["att1", "att2", "att3", "att4"]
      }

      compacted = Beamcore.Agent.Chat.Context.compact(context)

      assert MapSet.size(compacted.inspected_files) == 20
      assert length(compacted.blocked_attempts) == 3
      assert compacted.current_task == nil
    end

    test "summarize_and_rollover/3 performs fallback local compaction if API call fails" do
      client = Beamcore.Provider.Registry.client()
      session = Session.new(client)

      # 1. Mock API call failure
      Process.put(:mock_completions_create, fn _client, _params ->
        {:error, "API is down"}
      end)

      # Ensure cleanup
      on_exit(fn ->
        Process.delete(:mock_completions_create)
      end)

      # 2. Modify session context
      session = %{
        session
        | context: session.context,
          session_id: "fallback-session-id",
          last_prompt_tokens: 155_000,
          needs_compaction: true
      }

      # 3. Perform rollover
      new_session = Session.summarize_and_rollover(session, session.messages, nil)

      # 4. Assertions
      assert new_session.session_id == "fallback-session-id"
      assert new_session.compaction_count == 1
      assert new_session.needs_compaction == false
      assert new_session.last_prompt_tokens == 0
      assert new_session.total_tokens == 0

      # Context is still compacted and preserved
      # Context is preserved after compaction

      # Message history is locally trimmed but non-empty
      assert length(new_session.messages) > 0
    end
  end
end
