defmodule Beamcore.Agent.Chat.CorrectionCatchTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.{CorrectionCatch, Session}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key"
    })
  end

  describe "CorrectionCatch.stuck?/1" do
    test "returns false for empty list" do
      refute CorrectionCatch.stuck?([])
    end

    test "returns false if there are fewer than 5 assistant messages" do
      messages = [
        %{role: "user", content: "hello"},
        %{role: "assistant", content: "Actually, let me see..."},
        %{role: "assistant", content: "Oops, mistake."},
        %{role: "assistant", content: "Apologies, let me try again."},
        %{role: "assistant", content: "Actually, that was wrong."}
      ]

      refute CorrectionCatch.stuck?(messages)
    end

    test "returns true when last 5 assistant messages contain triggers" do
      messages = [
        %{role: "assistant", content: "Actually, let me try this..."},
        %{role: "user", content: "Wait, that's wrong"},
        %{role: "assistant", content: "This is too complicated, let me think."},
        %{role: "assistant", content: "Apologies, I made a mistake."},
        %{role: "assistant", content: "Actually, let me try again..."},
        %{role: "tool", content: "error output"},
        %{role: "assistant", content: "I apologize, let me fix it."}
      ]

      assert CorrectionCatch.stuck?(messages)
    end

    test "returns false if one of the last 5 assistant messages does not contain a trigger" do
      messages = [
        %{role: "assistant", content: "Actually, let me try this..."},
        %{role: "assistant", content: "This is too complicated, let me think."},
        %{role: "assistant", content: "Apologies, I made a mistake."},
        # No triggers in this assistant message:
        %{role: "assistant", content: "Creating a plan now..."},
        %{role: "assistant", content: "I apologize, let me fix it."}
      ]

      refute CorrectionCatch.stuck?(messages)
    end
  end

  describe "CorrectionCatch.correct_and_rollover/3" do
    test "compacts session history and injects diagnosis & corrected actions into system prompt" do
      client = Beamcore.Agent.OpenAI.client()
      session = Session.new(client)

      messages = [
        %{role: "user", content: "fix the bug"},
        %{role: "assistant", content: "Actually, let me try..."},
        %{role: "assistant", content: "I apologize, let me try..."}
      ]

      # Mock completions to return custom correction summary
      Process.put(:mock_completions_create, fn _client, params ->
        assert params.model == Beamcore.Agent.Chat.API.default_model()

        assert Enum.any?(params.messages, fn msg ->
                 content = msg[:content] || msg["content"] || ""
                 String.contains?(content, "stuck in a repetitive loop")
               end)

        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" =>
                   "Diagnosis: Repeating 'actually' and 'apologize'.\nCorrected Action: Do not apologize anymore. Do not use actually."
               }
             }
           ]
         }}
      end)

      rolled_session = CorrectionCatch.correct_and_rollover(session, messages, nil)

      assert rolled_session.compaction_count == 1
      assert length(rolled_session.messages) == 1
      system_msg = List.first(rolled_session.messages)
      role = system_msg[:role] || system_msg["role"]
      content = system_msg[:content] || system_msg["content"]
      assert role == "system"
      assert String.contains?(content, "SYSTEM INTERRUPT")
      assert String.contains?(content, "Do not apologize anymore")
    end

    test "chat loop detects loop, self-corrects, and resumes execution seamlessly" do
      client = Beamcore.Agent.OpenAI.client()
      session = Session.new(client)

      # Seed the session with 4 previous assistant messages that contain trigger phrases
      seeded_messages = [
        %{role: "system", content: "system prompt"},
        %{role: "user", content: "step 1"},
        %{role: "assistant", content: "Actually, let me try this first..."},
        %{role: "user", content: "step 2"},
        %{role: "assistant", content: "I apologize, I made a mistake."},
        %{role: "user", content: "step 3"},
        %{role: "assistant", content: "Oops, this is too complicated."},
        %{role: "user", content: "step 4"},
        %{role: "assistant", content: "Let's try one more time."}
      ]

      session = %{session | messages: seeded_messages}

      parent = self()
      Process.put(:mock_completions_calls, 0)

      Process.put(:mock_completions_create, fn _client, params ->
        call_num = Process.get(:mock_completions_calls) || 0
        Process.put(:mock_completions_calls, call_num + 1)

        send(parent, {:completion_called, call_num, params})

        case call_num do
          0 ->
            # The agent is answering the user's "step 5" prompt, and loops again (5th consecutive triggers)
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "role" => "assistant",
                     "content" => "Actually, let me try a different approach."
                   }
                 }
               ]
             }}

          1 ->
            # The CorrectionCatch.correct_and_rollover call to diagnose and summarize
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "role" => "assistant",
                     "content" =>
                       "Diagnosis: Getting stuck using 'actually'.\nCorrected Action: Proceed directly without 'actually'."
                   }
                 }
               ]
             }}

          2 ->
            # The resume/continuation call after correction
            {:ok,
             %{
               "choices" => [
                 %{
                   "message" => %{
                     "role" => "assistant",
                     "content" => "Now executing without loop: successfully completed task!"
                   }
                 }
               ]
             }}
        end
      end)

      # Send a message to run the turn
      updated_session =
        Beamcore.Agent.Chat.Loop.send_message(session, "step 5", nil, nil, silent: true)

      # Verify the sequence of calls and messages
      # Main assistant call
      assert_receive {:completion_called, 0, _}
      # Correction call
      assert_receive {:completion_called, 1, _}
      # Resumed execution call
      assert_receive {:completion_called, 2, _}

      # Verify the session got rolled over and has the successful final message
      last_msg = List.last(updated_session.messages)
      assert last_msg["role"] == "assistant" or last_msg[:role] == "assistant"
      assert (last_msg["content"] || last_msg[:content]) =~ "successfully completed task!"

      # Verify the system prompt in the rolled over session contains the diagnosis
      system_msg = List.first(updated_session.messages)
      assert (system_msg["content"] || system_msg[:content]) =~ "SYSTEM INTERRUPT"

      assert (system_msg["content"] || system_msg[:content]) =~
               "Diagnosis: Getting stuck using 'actually'"
    end
  end
end
