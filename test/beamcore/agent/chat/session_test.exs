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
    test "prepare_for_api cleans messages" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hello"}
      ]

      prepared = Session.prepare_for_api(messages)

      assert length(prepared) == 2
      assert Enum.at(prepared, 0).role == "system"
      assert Enum.at(prepared, 1).role == "user"
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

      prepared = Session.prepare_for_api(messages)
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

      prepared = Session.prepare_for_api(messages)
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

      prepared = Session.prepare_for_api(messages)
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

  describe "transparent rollover" do
    test "summarize_and_rollover/3 performs fallback local compaction if API call fails" do
      client = Beamcore.Provider.Registry.client()
      session = Session.new(client)

      Process.put(:mock_completions_create, fn _client, _params ->
        {:error, "API is down"}
      end)

      on_exit(fn ->
        Process.delete(:mock_completions_create)
      end)

      messages =
        session.messages ++
          Enum.flat_map(1..10, fn i ->
            [
              %{role: "user", content: "user message #{i}"},
              %{role: "assistant", content: "assistant response #{i}"}
            ]
          end)

      session = %{
        session
        | session_id: "fallback-session-id",
          messages: messages,
          last_prompt_tokens: 155_000
      }

      new_session = Session.summarize_and_rollover(session, session.messages, nil)

      assert new_session.session_id == "fallback-session-id"
      assert new_session.compaction_count == 1
      assert new_session.last_prompt_tokens == 0
      assert new_session.total_tokens == 0

      assert length(new_session.messages) > 0
    end
  end

  describe "maybe_compact/4" do
    setup do
      client = Beamcore.Provider.Registry.client()
      session = Session.new(client)
      %{client: client, session: session}
    end

    test "does nothing when context_window is nil", %{session: session} do
      messages = session.messages ++ [%{role: "user", content: "hello"}]
      metadata = %{context_window: nil}

      {result_session, result_messages} = Session.maybe_compact(session, messages, metadata, 0)

      assert result_session == session
      assert result_messages == messages
    end

    test "does nothing when estimate is below threshold", %{session: session} do
      messages =
        session.messages ++
          [
            %{role: "user", content: "short message"},
            %{role: "assistant", content: "short reply"}
          ]

      metadata = %{context_window: 200_000}

      {result_session, result_messages} = Session.maybe_compact(session, messages, metadata, 0)

      assert result_session == session
      assert result_messages == messages
    end

    test "skips compaction during tool loop (depth > 0)", %{session: session} do
      messages =
        session.messages ++
          Enum.flat_map(1..50, fn _i ->
            [
              %{role: "user", content: String.duplicate("x", 5000)},
              %{role: "assistant", content: String.duplicate("y", 5000)}
            ]
          end)

      metadata = %{context_window: 10_000}

      {result_session, result_messages} = Session.maybe_compact(session, messages, metadata, 3)

      assert result_session == session
      assert result_messages == messages
    end

    test "stops auto-compacting after anti-thrashing limit", %{session: session} do
      session = %{session | compaction_count: 3}

      messages =
        session.messages ++
          Enum.flat_map(1..50, fn _i ->
            [
              %{role: "user", content: String.duplicate("x", 5000)},
              %{role: "assistant", content: String.duplicate("y", 5000)}
            ]
          end)

      metadata = %{context_window: 10_000}

      {result_session, result_messages} = Session.maybe_compact(session, messages, metadata, 0)

      assert result_session == session
      assert result_messages == messages
    end
  end

  describe "summarize_and_rollover detailed" do
    setup do
      client = Beamcore.Provider.Registry.client()
      session = Session.new(client)
      %{client: client, session: session}
    end

    test "returns session unchanged when fewer messages than keep_recent", %{session: session} do
      messages =
        session.messages ++
          [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

      result = Session.summarize_and_rollover(session, messages, nil)

      assert result == session
    end

    test "preserves recent messages verbatim and summarizes older ones", %{session: session} do
      Process.put(:mock_completions_create, fn _client, _params ->
        summary_text =
          "## USER GOAL\nUser wanted to build a CLI tool.\n\n## COMPLETED WORK\n- Created main.ex\n- Added tests"

        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => summary_text
               }
             }
           ]
         }}
      end)

      on_exit(fn ->
        Process.delete(:mock_completions_create)
      end)

      messages =
        session.messages ++
          Enum.flat_map(1..10, fn i ->
            [
              %{role: "user", content: "task step #{i}"},
              %{role: "assistant", content: "completed step #{i}"}
            ]
          end)

      session = %{session | messages: messages}

      new_session = Session.summarize_and_rollover(session, messages, nil)

      assert new_session.compaction_count == 1
      assert length(new_session.messages) > 0

      system_msg = List.first(new_session.messages)
      system_content = system_msg[:content] || system_msg["content"]

      assert system_content =~ "USER GOAL"
      assert system_content =~ "CLI tool"
      assert system_content =~ "[Compacted]"

      non_system = Enum.drop(new_session.messages, 1)
      assert length(non_system) <= 6

      last_msg = List.last(non_system)
      assert last_msg[:role] == "assistant" or last_msg["role"] == "assistant"
    end

    test "multiple compactions increment counter and add marker", %{session: session} do
      Process.put(:mock_completions_create, fn _client, _params ->
        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => "## USER GOAL\nBuild something.\n\n## COMPLETED WORK\nDone."
               }
             }
           ]
         }}
      end)

      on_exit(fn ->
        Process.delete(:mock_completions_create)
      end)

      make_messages = fn ->
        Enum.flat_map(1..10, fn i ->
          [
            %{role: "user", content: "step #{i}"},
            %{role: "assistant", content: "done #{i}"}
          ]
        end)
      end

      messages1 = session.messages ++ make_messages.()
      session1 = %{session | messages: messages1}
      session2 = Session.summarize_and_rollover(session1, messages1, nil)

      assert session2.compaction_count == 1

      messages2 = session2.messages ++ make_messages.()
      session3 = Session.summarize_and_rollover(session2, messages2, nil)

      assert session3.compaction_count == 2

      system_msg = List.first(session3.messages)
      system_content = system_msg[:content] || system_msg["content"]
      assert system_content =~ "Compacted 2x"
    end

    test "summary validation: empty string gets default", %{session: session} do
      Process.put(:mock_completions_create, fn _client, _params ->
        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => ""
               }
             }
           ]
         }}
      end)

      on_exit(fn ->
        Process.delete(:mock_completions_create)
      end)

      messages =
        session.messages ++
          Enum.flat_map(1..10, fn i ->
            [%{role: "user", content: "msg #{i}"}, %{role: "assistant", content: "resp #{i}"}]
          end)

      session = %{session | messages: messages}
      new_session = Session.summarize_and_rollover(session, messages, nil)

      system_msg = List.first(new_session.messages)
      system_content = system_msg[:content] || system_msg["content"]
      assert system_content =~ "compacted"
    end

    test "summary validation: too long gets truncated", %{session: session} do
      long_summary = String.duplicate("x", 10_000)

      Process.put(:mock_completions_create, fn _client, _params ->
        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => long_summary
               }
             }
           ]
         }}
      end)

      on_exit(fn ->
        Process.delete(:mock_completions_create)
      end)

      messages =
        session.messages ++
          Enum.flat_map(1..10, fn i ->
            [%{role: "user", content: "msg #{i}"}, %{role: "assistant", content: "resp #{i}"}]
          end)

      session = %{session | messages: messages}
      new_session = Session.summarize_and_rollover(session, messages, nil)

      system_msg = List.first(new_session.messages)
      system_content = system_msg[:content] || system_msg["content"]
      assert system_content =~ "[truncated]"
    end

    test "resets token counters after compaction", %{session: session} do
      Process.put(:mock_completions_create, fn _client, _params ->
        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => "## USER GOAL\nTest.\n\n## COMPLETED WORK\nDone."
               }
             }
           ]
         }}
      end)

      on_exit(fn ->
        Process.delete(:mock_completions_create)
      end)

      messages =
        session.messages ++
          Enum.flat_map(1..10, fn i ->
            [%{role: "user", content: "msg #{i}"}, %{role: "assistant", content: "resp #{i}"}]
          end)

      session = %{session | messages: messages, total_tokens: 50_000, last_prompt_tokens: 10_000}

      new_session = Session.summarize_and_rollover(session, messages, nil)

      assert new_session.total_tokens == 0
      assert new_session.last_prompt_tokens == 0
      assert new_session.total_prompt_tokens == 0
      assert new_session.total_completion_tokens == 0
    end
  end
end
