defmodule Beamcore.Agent.Chat.CorrectionCatchTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.{CorrectionCatch, Session}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "BEAMCORE_SEARCH_CONDUCTOR" => "false"
    })
  end

  # ----- Helper: build an assistant message with tool_calls -----

  defp tool_call_msg(name, args) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => "call_#{:rand.uniform(100_000)}",
          "function" => %{
            "name" => name,
            "arguments" => Jason.encode!(args)
          }
        }
      ]
    }
  end

  defp tool_response_msg(name) do
    %{
      "role" => "tool",
      "tool_call_id" => "call_#{:rand.uniform(100_000)}",
      "name" => name,
      "content" => "ok"
    }
  end

  defp plain_assistant_msg(content) do
    %{"role" => "assistant", "content" => content}
  end

  # ===== stuck?/1 =====

  describe "stuck?/1 — no false positives" do
    test "returns false for empty list" do
      assert CorrectionCatch.stuck?([]) == false
    end

    test "returns false for non-list input" do
      assert CorrectionCatch.stuck?(nil) == false
    end

    test "returns false for assistant messages with trigger-like text (text is not a signal)" do
      messages = [
        plain_assistant_msg("Actually, let me try a different approach."),
        plain_assistant_msg("I apologize, that was wrong."),
        plain_assistant_msg("This is too complicated, let me think."),
        plain_assistant_msg("Let me try again with a simpler method."),
        plain_assistant_msg("Actually, I made a mistake earlier.")
      ]

      assert CorrectionCatch.stuck?(messages) == false
    end

    test "returns false when different tools are called on different files" do
      messages = [
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "lib/app.ex"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "mix.exs"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "test/app_test.exs"}),
        tool_response_msg("read_file")
      ]

      assert CorrectionCatch.stuck?(messages) == false
    end

    test "returns false for a normal productive tool chain" do
      messages = [
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("edit_file", %{"path" => "lib/app.ex", "content" => "new code"}),
        tool_response_msg("edit_file"),
        tool_call_msg("run_command", %{"command" => "mix test"}),
        tool_response_msg("run_command"),
        tool_call_msg("read_file", %{"path" => "test/app_test.exs"}),
        tool_response_msg("read_file")
      ]

      assert CorrectionCatch.stuck?(messages) == false
    end

    test "returns false for 2 identical tool calls (under threshold)" do
      messages = [
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file")
      ]

      assert CorrectionCatch.stuck?(messages) == false
    end
  end

  describe "stuck?/1 — exact tool repetition" do
    test "detects same tool called 3 times with identical args" do
      messages = [
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file")
      ]

      assert {true, reason} = CorrectionCatch.stuck?(messages)
      assert reason =~ "read_file"
      assert reason =~ "3 times"
    end

    test "detects same tool called 5 times with identical args" do
      messages =
        Enum.flat_map(1..5, fn _i ->
          [
            tool_call_msg("read_file", %{"path" => "README.md"}),
            tool_response_msg("read_file")
          ]
        end)

      assert {true, reason} = CorrectionCatch.stuck?(messages)
      assert reason =~ "read_file"
      assert reason =~ "5 times"
    end

    test "detects same edit_file with identical args" do
      messages =
        Enum.flat_map(1..3, fn _i ->
          [
            tool_call_msg("edit_file", %{
              "path" => "lib/app.ex",
              "old" => "foo",
              "new" => "bar"
            }),
            tool_response_msg("edit_file")
          ]
        end)

      assert {true, reason} = CorrectionCatch.stuck?(messages)
      assert reason =~ "edit_file"
    end

    test "does NOT trigger when args differ" do
      messages = [
        tool_call_msg("edit_file", %{"path" => "lib/app.ex", "old" => "foo", "new" => "bar"}),
        tool_response_msg("edit_file"),
        tool_call_msg("edit_file", %{"path" => "lib/app.ex", "old" => "bar", "new" => "baz"}),
        tool_response_msg("edit_file"),
        tool_call_msg("edit_file", %{"path" => "lib/app.ex", "old" => "baz", "new" => "qux"}),
        tool_response_msg("edit_file")
      ]

      assert CorrectionCatch.stuck?(messages) == false
    end
  end

  describe "stuck?/1 — tool oscillation" do
    test "detects A-B-A-B-A-B oscillation" do
      messages =
        Enum.flat_map(1..3, fn i ->
          [
            tool_call_msg("edit_file", %{"path" => "lib/app.ex", "content" => "v#{i}"}),
            tool_response_msg("edit_file"),
            tool_call_msg("run_command", %{"command" => "mix test attempt #{i}"}),
            tool_response_msg("run_command")
          ]
        end)

      assert {true, reason} = CorrectionCatch.stuck?(messages)
      assert reason =~ "oscillating"
      assert reason =~ "edit_file"
      assert reason =~ "run_command"
    end

    test "detects A-B-C-A-B-C-A-B-C oscillation" do
      messages =
        Enum.flat_map(1..3, fn i ->
          [
            tool_call_msg("read_file", %{"path" => "lib/app_v#{i}.ex"}),
            tool_response_msg("read_file"),
            tool_call_msg("edit_file", %{"path" => "lib/app_v#{i}.ex", "content" => "x#{i}"}),
            tool_response_msg("edit_file"),
            tool_call_msg("run_command", %{"command" => "mix test round #{i}"}),
            tool_response_msg("run_command")
          ]
        end)

      assert {true, reason} = CorrectionCatch.stuck?(messages)
      assert reason =~ "oscillating"
    end

    test "does NOT trigger for non-repeating varied sequence" do
      messages = [
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("edit_file", %{"path" => "lib/app.ex", "content" => "v1"}),
        tool_response_msg("edit_file"),
        tool_call_msg("run_command", %{"command" => "mix test"}),
        tool_response_msg("run_command"),
        tool_call_msg("read_file", %{"path" => "test/app_test.exs"}),
        tool_response_msg("read_file"),
        tool_call_msg("edit_file", %{"path" => "test/app_test.exs", "content" => "v2"}),
        tool_response_msg("edit_file")
      ]

      assert CorrectionCatch.stuck?(messages) == false
    end

    test "does NOT trigger oscillation for consecutive calls of the same tool with different arguments (e.g. parallel reads)" do
      messages = [
        tool_call_msg("read", %{"filePath" => "lib/beamcore/agent/agent.ex"}),
        tool_response_msg("read"),
        tool_call_msg("read", %{"filePath" => "mix.exs"}),
        tool_response_msg("read"),
        tool_call_msg("read", %{"filePath" => "lib/tui/render.ex"}),
        tool_response_msg("read"),
        tool_call_msg("read", %{"filePath" => "lib/beamcore/agent/chat/session.ex"}),
        tool_response_msg("read"),
        tool_call_msg("read", %{"filePath" => "lib/beamcore/agent/chat/rate_limiter.ex"}),
        tool_response_msg("read"),
        tool_call_msg("read", %{"filePath" => "lib/beamcore/agent/core/status_bar.ex"}),
        tool_response_msg("read")
      ]

      assert CorrectionCatch.stuck?(messages) == false
    end

    test "includes short argument description in the oscillation reason" do
      messages =
        Enum.flat_map(1..3, fn i ->
          [
            tool_call_msg("edit_file", %{"path" => "lib/app.ex", "content" => "v#{i}"}),
            tool_response_msg("edit_file"),
            tool_call_msg("run_command", %{"command" => "mix test attempt #{i}"}),
            tool_response_msg("run_command")
          ]
        end)

      assert {true, reason} = CorrectionCatch.stuck?(messages)
      assert reason =~ "oscillating pattern:"
      assert reason =~ "edit_file(path: lib/app.ex)"
      assert reason =~ "run_command(command: mix test attempt 1)"
    end
  end

  # ===== Fingerprinting =====

  describe "extract_tool_fingerprints/1" do
    test "extracts fingerprints from assistant tool_calls messages" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        plain_assistant_msg("Here's the content"),
        tool_call_msg("edit_file", %{"path" => "lib/app.ex", "content" => "new"}),
        tool_response_msg("edit_file")
      ]

      fps = CorrectionCatch.extract_tool_fingerprints(messages)
      assert length(fps) == 2
      assert [{"read_file", _}, {"edit_file", _}] = fps
    end

    test "handles string-encoded JSON arguments" do
      messages = [
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "read_file",
                "arguments" => ~s({"path": "README.md"})
              }
            }
          ]
        }
      ]

      fps = CorrectionCatch.extract_tool_fingerprints(messages)
      assert [{"read_file", %{"path" => "README.md"}}] = fps
    end

    test "normalizes whitespace in string arg values" do
      messages = [
        tool_call_msg("read_file", %{"path" => "  README.md  "})
      ]

      fps = CorrectionCatch.extract_tool_fingerprints(messages)
      assert [{"read_file", %{"path" => "README.md"}}] = fps
    end

    test "skips messages without tool_calls" do
      messages = [
        plain_assistant_msg("no tools"),
        %{"role" => "user", "content" => "question"}
      ]

      assert CorrectionCatch.extract_tool_fingerprints(messages) == []
    end
  end

  # ===== correct_and_rollover/4 =====

  describe "correct_and_rollover/4" do
    test "performs correction and returns rolled-over session with diagnosis" do
      client = Beamcore.OpenAI.client()
      session = Session.new(client)

      messages = [
        %{role: "user", content: "fix the bug"},
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file"),
        tool_call_msg("read_file", %{"path" => "README.md"}),
        tool_response_msg("read_file")
      ]

      Process.put(:mock_completions_create, fn _client, params ->
        assert params.model == Beamcore.Agent.Chat.API.default_model()

        assert Enum.any?(params.messages, fn msg ->
                 content = msg[:content] || msg["content"] || ""
                 String.contains?(content, "mechanical loop")
               end)

        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" =>
                   "Diagnosis: Reading README.md repeatedly.\nCorrected: Read the file once and proceed."
               }
             }
           ]
         }}
      end)

      reason = "read_file called 3 times with identical arguments"
      rolled_session = CorrectionCatch.correct_and_rollover(session, messages, reason, nil)

      assert rolled_session.correction_count == 1
      assert rolled_session.compaction_count == 1
      assert length(rolled_session.messages) == 1

      system_msg = List.first(rolled_session.messages)
      content = system_msg[:content] || system_msg["content"]
      assert String.contains?(content, "SYSTEM INTERRUPT")
      assert String.contains?(content, "read_file called 3 times")
      assert String.contains?(content, "Read the file once and proceed")
    end

    test "skips correction when max corrections reached" do
      client = Beamcore.OpenAI.client()
      session = %{Session.new(client) | correction_count: 3}

      messages = [
        %{role: "user", content: "do something"},
        tool_call_msg("read_file", %{"path" => "README.md"})
      ]

      # Should not call API at all
      Process.put(:mock_completions_create, fn _client, _params ->
        flunk("API should not be called when max corrections reached")
      end)

      result = CorrectionCatch.correct_and_rollover(session, messages, "some reason", nil)

      # Returns session unchanged
      assert result.correction_count == 3
    end
  end

  # ===== Integration test =====

  describe "loop integration" do
    test "loop detects tool repetition, self-corrects, and resumes" do
      client = Beamcore.OpenAI.client()
      session = Session.new(client)

      # Seed history with 2 prior identical read_file calls
      seeded_messages =
        [%{role: "system", content: "system prompt"}, %{role: "user", content: "help me"}] ++
          Enum.flat_map(1..2, fn _i ->
            [
              tool_call_msg("read_file", %{"path" => "README.md"}),
              %{role: "tool", tool_call_id: "tc", name: "read_file", content: "readme content"}
            ]
          end)

      session = %{session | messages: seeded_messages}

      parent = self()
      Process.put(:mock_completions_calls, 0)

      Process.put(:mock_completions_create, fn _client, _params ->
        call_num = Process.get(:mock_completions_calls) || 0
        Process.put(:mock_completions_calls, call_num + 1)
        send(parent, {:completion_called, call_num})

        case call_num do
          0 ->
            # 3rd identical read_file call — triggers loop detection
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "role" => "assistant",
                     "content" => "",
                     "tool_calls" => [
                       %{
                         "id" => "call_loop",
                         "function" => %{
                           "name" => "read_file",
                           "arguments" => Jason.encode!(%{"path" => "README.md"})
                         }
                       }
                     ]
                   }
                 }
               ]
             }}

          1 ->
            # Correction diagnosis call
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "role" => "assistant",
                     "content" =>
                       "Diagnosis: Repeatedly reading README.md.\nCorrected: Use cached content."
                   }
                 }
               ]
             }}

          2 ->
            # Resumed execution after correction
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "role" => "assistant",
                     "content" => "Task completed successfully using cached content."
                   }
                 }
               ]
             }}
        end
      end)

      updated_session =
        Beamcore.Agent.Chat.Loop.send_message(session, "continue", nil, nil, silent: true)

      assert_receive {:completion_called, 0}
      assert_receive {:completion_called, 1}
      assert_receive {:completion_called, 2}

      # Session was corrected
      system_msg = List.first(updated_session.messages)
      assert (system_msg["content"] || system_msg[:content]) =~ "SYSTEM INTERRUPT"

      # Final message is the successful completion
      last_msg = List.last(updated_session.messages)
      assert (last_msg["content"] || last_msg[:content]) =~ "Task completed successfully"
    end
  end
end
