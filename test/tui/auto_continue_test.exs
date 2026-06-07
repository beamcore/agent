defmodule Beamcore.TUI.AutoContinueTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Events
  alias Beamcore.TUI.State
  alias Beamcore.Agent.Chat.Session

  setup do
    client = %{provider: "test", model: "test"}

    session = %Session{
      messages: [],
      client: client,
      session_id: "test-session",
      log_file: "/dev/null",
      screen_type: :research,
      workspace_root: "/tmp",
      context: Beamcore.Agent.Chat.Context.new(:unknown, :unknown)
    }

    state = %State{
      session: session,
      messages: [],
      activity: [],
      status: :idle,
      screen_type: :research
    }

    %{state: state}
  end

  test "does not auto-continue if screen_type is not :research", %{state: state} do
    state = %{
      state
      | screen_type: :agent,
        session: %{
          state.session
          | screen_type: :agent,
            messages: [%{role: "assistant", content: "hello"}]
        }
    }

    updated = Events.maybe_auto_continue(state)
    assert updated == state
  end

  test "does not auto-continue if status is :paused", %{state: state} do
    state = %{
      state
      | status: :paused,
        session: %{state.session | messages: [%{role: "assistant", content: "hello"}]}
    }

    updated = Events.maybe_auto_continue(state)
    assert updated == state
  end

  test "does not auto-continue if last message was from user", %{state: state} do
    state = %{state | session: %{state.session | messages: [%{role: "user", content: "hello"}]}}
    updated = Events.maybe_auto_continue(state)
    assert updated == state
  end

  test "does not auto-continue if last message contains RESEARCH_COMPLETE", %{state: state} do
    state = %{
      state
      | session: %{
          state.session
          | messages: [%{role: "assistant", content: "Done. RESEARCH_COMPLETE"}]
        }
    }

    updated = Events.maybe_auto_continue(state)
    assert updated == state
  end

  test "auto-continues if last message is assistant response without RESEARCH_COMPLETE", %{
    state: state
  } do
    state = %{
      state
      | session: %{
          state.session
          | messages: [
              %{role: "assistant", content: "Planning complete. Proceeding to gather data."}
            ]
        }
    }

    updated = Events.maybe_auto_continue(state)
    assert updated.status == :thinking
    assert is_pid(updated.worker)

    if is_pid(updated.worker) do
      Process.exit(updated.worker, :kill)
    end
  end

  test "API.extract_reasoning extracts reasoning from reasoning_content or reasoning fields" do
    msg1 = %{"content" => "Hello", "reasoning_content" => "Thinking process"}
    assert Beamcore.Agent.Chat.API.extract_reasoning(msg1) == {"Hello", "Thinking process"}

    msg2 = %{"content" => "Hello", "reasoning" => "Thinking process 2"}
    assert Beamcore.Agent.Chat.API.extract_reasoning(msg2) == {"Hello", "Thinking process 2"}
  end

  test "API.extract_reasoning extracts reasoning from <think> tags in content" do
    msg = %{"content" => "<think>I should calculate X.</think>\nHere is the answer."}

    assert Beamcore.Agent.Chat.API.extract_reasoning(msg) ==
             {"Here is the answer.", "I should calculate X."}
  end

  test "API.extract_reasoning returns nil reasoning if not present" do
    msg = %{"content" => "Hello standard content"}
    assert Beamcore.Agent.Chat.API.extract_reasoning(msg) == {"Hello standard content", nil}
  end

  test "Dispatcher normalizes write_file and read_file tool calls" do
    {name1, args1} =
      Beamcore.Agent.Tools.Dispatcher.normalize_tool_call("write_file", %{
        "path" => "a.md",
        "content" => "test"
      })

    assert name1 == "modify_file"

    assert args1 == %{
             "operation" => "create_file",
             "path" => "a.md",
             "content" => "test",
             "overwrite" => true
           }

    {name2, args2} =
      Beamcore.Agent.Tools.Dispatcher.normalize_tool_call("write_to_file", %{
        "path" => "b.md",
        "content" => "test2"
      })

    assert name2 == "modify_file"

    assert args2 == %{
             "operation" => "create_file",
             "path" => "b.md",
             "content" => "test2",
             "overwrite" => true
           }

    {name3, args3} =
      Beamcore.Agent.Tools.Dispatcher.normalize_tool_call("read_file", %{"path" => "c.md"})

    assert name3 == "read"
    assert args3 == %{"path" => "c.md"}
  end
end
