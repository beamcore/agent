defmodule Beamcore.Agent.Chat.ResearchLoopTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.{Loop, Session}

  setup do
    tmp_dir = Path.join([System.tmp_dir!(), "beamcore_research_test_#{:rand.uniform(1_000_000)}"])
    File.mkdir_p!(tmp_dir)

    log_file = Path.join(tmp_dir, "test_session.json")

    session = %Session{
      messages: [%{role: "system", content: "System prompt"}],
      session_id: "test-session",
      log_file: log_file,
      workspace_root: tmp_dir,
      screen_type: :research,
      roles: nil,
      client: nil,
      context: Beamcore.Agent.Chat.Context.new(:unknown, :unknown)
    }

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, session: session, tmp_dir: tmp_dir}
  end

  test "inject_research_harness on a research session with empty workspace", %{session: session} do
    # Add first user request
    session = %{
      session
      | messages:
          session.messages ++
            [%{role: "user", content: "Research the history of Elixir language."}]
    }

    messages = Loop.test_inject_research_harness(session.messages, session)

    assert length(messages) == 3
    [system_msg, harness_msg, user_msg] = messages

    assert system_msg.content == "System prompt"
    assert user_msg.content == "Research the history of Elixir language."

    assert String.contains?(harness_msg.content, "[DEEP RESEARCH WORKFLOW]")

    assert String.contains?(
             harness_msg.content,
             "Research the history of Elixir language."
           )

    assert String.contains?(harness_msg.content, "(No research artifacts created yet)")
    assert String.contains?(harness_msg.content, "(research_index.md does not exist yet)")
  end

  test "inject_research_harness on non-research session does not alter messages", %{
    session: session
  } do
    session = %{session | screen_type: :agent}

    session = %{
      session
      | messages: session.messages ++ [%{role: "user", content: "Research history."}]
    }

    messages = Loop.test_inject_research_harness(session.messages, session)
    assert messages == session.messages
  end

  test "inject_research_harness lists md files and index content", %{
    session: session,
    tmp_dir: tmp_dir
  } do
    # Create some markdown files
    File.write!(
      Path.join(tmp_dir, "research_index.md"),
      "Status: In progress\nGoals:\n- Done 1\n- Todo 2"
    )

    File.write!(Path.join(tmp_dir, "findings.md"), "Here are the Elixir findings.")
    File.mkdir_p!(Path.join(tmp_dir, "subdir"))
    File.write!(Path.join(tmp_dir, "subdir/notes.md"), "More notes.")

    session = %{
      session
      | messages: session.messages ++ [%{role: "user", content: "Research Elixir"}]
    }

    messages = Loop.test_inject_research_harness(session.messages, session)
    harness_msg = Enum.at(messages, 1)

    assert String.contains?(harness_msg.content, "findings.md")
    assert String.contains?(harness_msg.content, "subdir/notes.md")
    # Should reject index from file list
    refute String.contains?(harness_msg.content, "- research_index.md")

    assert String.contains?(harness_msg.content, "Status: In progress")
    assert String.contains?(harness_msg.content, "Goals:")
  end

  test "inject_research_harness reads main topic from log file if compacted/resumed", %{
    session: session
  } do
    # Simulate compaction where messages doesn't contain the user message, but the log file does
    File.write!(
      session.log_file,
      Jason.encode!(%{role: "user", content: "Persisted request from log"}) <> "\n"
    )

    # messages list only has system prompt
    messages = Loop.test_inject_research_harness(session.messages, session)
    harness_msg = Enum.at(messages, 1)

    assert String.contains?(harness_msg.content, "Persisted request from log")
  end

  test "maybe_auto_continue triggers next turn if conditions are met", %{session: session} do
    # Create a state
    state = %Beamcore.TUI.State{
      screen_type: :research,
      status: :idle,
      session: session
    }

    # Ensure last message is assistant
    session_with_assistant = %{
      session
      | messages:
          session.messages ++
            [
              %{role: "user", content: "research something"},
              %{role: "assistant", content: "I am researching..."}
            ]
    }

    state_with_assistant = %{state | session: session_with_assistant}

    # Call maybe_auto_continue
    new_state = Beamcore.TUI.Events.maybe_auto_continue(state_with_assistant)

    # It should have spawned a worker and changed status to :thinking!
    assert new_state.status == :thinking
    assert new_state.worker != nil

    # Clean up spawned worker
    if new_state.worker, do: Process.exit(new_state.worker, :kill)
  end
end
