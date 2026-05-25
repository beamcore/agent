defmodule Beamcore.Agent.TUI.StateComponentsTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.{Context, Session, ToolPolicy}
  alias Beamcore.Agent.TUI.Components.{Confirmation, EmptyState, Help, Mascot, StatusBar}
  alias Beamcore.Agent.TUI.{Events, State}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })

    session = Beamcore.Agent.OpenAI.client() |> Session.new()
    state = %State{session: session, messages: [], activity: [], status: :idle, unicode?: true}

    %{session: session, state: state}
  end

  test "command palette and help include yolo" do
    command_names = Enum.map(Events.commands(), & &1.name)

    assert "yolo" in command_names
    assert Help.widget().content.text =~ "/yolo"
  end

  test "empty state is product-facing and includes mascot hints", %{state: state} do
    widget = state |> EmptyState.text() |> EmptyState.widget()

    assert widget.text =~ "BEAMCORE.AGENT"
    assert widget.text =~ "Tool calls and plans"
    assert widget.text =~ "/help"
    refute widget.text =~ "%{"
  end

  test "mascot has terminal-safe animation frames" do
    assert Mascot.frame(:running, 0, true) != Mascot.frame(:running, 1, true)
    assert Mascot.frame(0, false) =~ "b"
    assert Mascot.frame(:tool_running, 0, true) != Mascot.frame(:tool_running, 1, true)
    assert Mascot.portrait(:thinking, 2, true) =~ "◢▣◣"
  end

  test "animation ticks are throttled and mark state dirty", %{state: state} do
    refute State.animation_due?(state, 100)
    assert State.animation_due?(state, 600)

    ticked = State.tick(state, 600) |> State.mark_dirty()

    assert ticked.spinner_step == state.spinner_step + 1
    assert ticked.render_dirty?
    refute State.animation_due?(ticked, 700)
  end

  test "scroll offset is updated and new messages do not yank user from history", %{state: state} do
    scrolled = State.scroll_up(state, 500)
    assert scrolled.scroll_offset == 500

    still_scrolled = State.add_message(scrolled, :assistant, "new message while reading history")
    assert still_scrolled.scroll_offset == 500

    bottom = State.scroll_down(still_scrolled, 600)
    assert bottom.scroll_offset == 0
  end

  test "pending confirmation panel renders plan details", %{session: session} do
    result =
      Beamcore.Agent.Tools.Plan.execute(%{
        "summary" => "Create a module",
        "create_files" => ["scratch/a.ex"],
        "modify_files" => ["README.md"],
        "delete_files" => ["scratch/old.ex"],
        "allowed_tools" => ["write", "mix"],
        "validation" => "mix test",
        "risks" => ["Small scoped change"]
      })

    session = %{
      session
      | pending_user_message: "Create a module",
        context: Context.update_from_tool(session.context, "plan", %{}, result)
    }

    text = session |> State.pending_action() |> Confirmation.text()

    assert text =~ "Create a module"
    assert text =~ "scratch/a.ex"
    assert text =~ "README.md"
    assert text =~ "mix test"
    assert text =~ "/confirm"
    assert text =~ "/cancel"
  end

  test "activity events are compact and avoid raw payloads", %{state: state} do
    content = String.duplicate("def x, do: :ok\n", 200)

    state =
      state
      |> State.add_activity(
        "write",
        %{"filePath" => "lib/foo.ex", "content" => content},
        :running
      )
      |> State.update_activity(
        "write",
        %{"filePath" => "lib/foo.ex", "content" => content},
        "Wrote file"
      )

    [event] = state.activity

    assert event.label == "write lib/foo.ex (3000 bytes)"
    assert event.status == :done
    refute event.summary =~ content
    refute inspect(event) =~ content
  end

  test "activity labels use very-pretty compact tool formatting" do
    patch = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@
    -old
    +new
    """

    cases = [
      {"read", %{"filePath" => "README.md"}, "read README.md"},
      {"write", %{"filePath" => "lib/foo.ex", "content" => "abc"}, "write lib/foo.ex (3 bytes)"},
      {"edit", %{"path" => "lib/foo.ex", "new_string" => "updated"}, "edit lib/foo.ex (7 bytes)"},
      {"patch", %{"patch_content" => patch}, "patch 1 files"},
      {"mix", %{"command" => "test", "args" => "test/agent_test.exs"},
       "mix test test/agent_test.exs"},
      {"git", %{"operation" => "status"}, "git status"},
      {"fs", %{"operation" => "mkdir", "path" => "lib/new_dir"}, "fs mkdir lib/new_dir"},
      {"task", %{"name" => "sneezing_walrus", "model" => "mistral-small"},
       "task sneezing_walrus (mistral-small)"},
      {"image_generation", %{"output_path" => "generated/file.png"},
       "image_generation -> generated/file.png"}
    ]

    for {name, args, expected_label} <- cases do
      assert %{label: ^expected_label} = State.compact_activity(name, args, :queued)
    end
  end

  test "blocked activity labels stay compact and clearly marked" do
    event =
      State.compact_activity(
        "write",
        %{"filePath" => "scratch/a.ex", "content" => "bad"},
        :blocked,
        "Error: Mutation requires a confirmed plan."
      )

    assert event.label == "blocked write scratch/a.ex (3 bytes)"
    assert event.status == :blocked
    assert event.result =~ "Mutation requires"
    refute event.label =~ "%{"
    refute event.summary =~ "%{"
  end

  test "very-pretty-inspired summaries avoid raw maps and long payloads" do
    task =
      State.compact_activity(
        "task",
        %{
          "name" => "dusty_cat",
          "model" => "mistral-medium",
          "prompt" => String.duplicate("inspect the repo ", 30)
        },
        :running
      )

    git = State.compact_activity("git", %{"operation" => "diff", "base" => "origin/main"}, :done)

    fs =
      State.compact_activity(
        "fs",
        %{"operation" => "move", "path" => "a", "target" => "b"},
        :done
      )

    assert task.summary =~ "name: dusty_cat"
    assert task.summary =~ "model: mistral-medium"
    assert String.length(task.summary) < 180
    assert git.summary =~ "op: diff"
    assert git.summary =~ "base: origin/main"
    assert fs.summary =~ "op: move"
    assert fs.summary =~ "target: b"
    refute inspect([task, git, fs]) =~ String.duplicate("inspect the repo ", 30)
  end

  test "TUI activity uses shared display labels without Pretty renderer output" do
    event =
      State.compact_activity(
        "mix",
        %{"command" => "test", "args" => "test/agent/tui/state_components_test.exs"},
        :running
      )

    assert event.label == "mix test test/agent/tui/state_components_test.exs"
    refute event.label =~ "\e["

    tui_sources =
      "lib/agent/tui/**/*.ex"
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    refute tui_sources =~ "Pretty.print_"
  end

  test "image generation activity is represented compactly", %{state: state} do
    result =
      Jason.encode!(%{
        ok: true,
        summary: "Generated image.",
        files: ["generated/architecture.png"]
      })

    state =
      State.update_activity(
        state,
        "image_generation",
        %{
          "prompt" => String.duplicate("terminal architecture ", 30),
          "output_path" => "generated/architecture.png"
        },
        result
      )

    [event] = state.activity

    assert event.label == "image_generation -> generated/architecture.png"
    assert event.summary =~ "output generated/architecture.png"
    assert event.summary =~ "open generated/architecture.png"
    assert String.length(event.summary) < 260
  end

  test "status bar reflects baseline yolo state", %{state: state, session: session} do
    state = %{state | session: %{session | policy_override: ToolPolicy.yolo()}}

    as    widget = StatusBar.widget(state, :wide)
    text = widget.text
    content = if is_binary(text), do: text, else: text |> List.first() |> Map.get(:spans, []) |> Enum.map(& &1.content) |> Enum.join()
    assert content =~ "YOLO"

  test "runtime policy is not bypassed before confirmation" do
    assert {:error, reason} =
             ToolPolicy.allow_tool_call(ToolPolicy.default(), "write", %{
               "filePath" => "scratch/a.ex"
             })

    assert reason =~ "Mutation requires"
  end

  test "TUI input history sliding and draft restoration works via Up/Down keys" do
    textarea = ExRatatui.textarea_new()
    ExRatatui.textarea_set_value(textarea, "draft")

    state = %State{
      textarea: textarea,
      history: ["first", "second"],
      history_index: nil,
      history_draft: ""
    }

    # 1. First Up key press captures draft and goes to the most recent entry
    up_event = %ExRatatui.Event.Key{code: "up", modifiers: [], kind: "press"}
    {:noreply, state} = Events.handle_event(up_event, state)
    assert state.history_index == 1
    assert state.history_draft == "draft"
    assert ExRatatui.textarea_get_value(state.textarea) == "second"

    # 2. Second Up key press goes to the older entry
    {:noreply, state} = Events.handle_event(up_event, state)
    assert state.history_index == 0
    assert ExRatatui.textarea_get_value(state.textarea) == "first"

    # 3. Third Up key press stays at the oldest entry (0)
    {:noreply, state} = Events.handle_event(up_event, state)
    assert state.history_index == 0
    assert ExRatatui.textarea_get_value(state.textarea) == "first"

    # 4. Down key press goes back to the newer entry (1)
    down_event = %ExRatatui.Event.Key{code: "down", modifiers: [], kind: "press"}
    {:noreply, state} = Events.handle_event(down_event, state)
    assert state.history_index == 1
    assert ExRatatui.textarea_get_value(state.textarea) == "second"

    # 5. Second Down key press restores the draft and resets history_index to nil
    {:noreply, state} = Events.handle_event(down_event, state)
    assert state.history_index == nil
    assert ExRatatui.textarea_get_value(state.textarea) == "draft"

    # 6. Typing a new character resets the index to nil
    # We navigate back up first
    {:noreply, state} = Events.handle_event(up_event, state)
    assert state.history_index == 1

    # User types a character (e.g. "a")
    char_event = %ExRatatui.Event.Key{code: "a", modifiers: [], kind: "press"}
    {:noreply, state} = Events.handle_event(char_event, state)
    assert state.history_index == nil
  end

  test "TUI handles context-aware mouse scroll events" do
    {width, height} = ExRatatui.terminal_size()

    areas =
      Beamcore.Agent.TUI.Layout.areas(%ExRatatui.Layout.Rect{
        x: 0,
        y: 0,
        width: width,
        height: height
      })

    # Test scrolling chat (always exists)
    chat_rect = areas.chat
    state = %State{scroll_offset: 0}

    # Scroll up over chat
    mouse_up_chat = %ExRatatui.Event.Mouse{
      kind: "scroll_up",
      x: chat_rect.x,
      y: chat_rect.y
    }

    {:noreply, state} = Events.handle_event(mouse_up_chat, state)
    assert state.scroll_offset == 3

    # Scroll down over chat
    mouse_down_chat = %ExRatatui.Event.Mouse{
      kind: "scroll_down",
      x: chat_rect.x,
      y: chat_rect.y
    }

    {:noreply, state} = Events.handle_event(mouse_down_chat, state)
    assert state.scroll_offset == 0

    # Test scrolling activity if it exists in the layout mode (e.g. :wide or :medium)
    case areas do
      %{activity: activity_rect} ->
        state = %State{
          activity: [
            %{
              id: 1,
              name: "write",
              target: "a.ex",
              status: :done,
              label: "write a.ex",
              summary: "",
              result: ""
            },
            %{
              id: 2,
              name: "read",
              target: "b.ex",
              status: :done,
              label: "read b.ex",
              summary: "",
              result: ""
            }
          ],
          selected_activity: 0,
          show_activity_details: false
        }

        # Scroll up over activity pane -> moves to older/next activity item (index 1)
        mouse_up_activity = %ExRatatui.Event.Mouse{
          kind: "scroll_up",
          x: activity_rect.x,
          y: activity_rect.y
        }

        {:noreply, state} = Events.handle_event(mouse_up_activity, state)
        assert state.selected_activity == 1
        assert state.show_activity_details == true

        # Scroll down over activity pane -> moves to newer/previous activity item (index 0)
        mouse_down_activity = %ExRatatui.Event.Mouse{
          kind: "scroll_down",
          x: activity_rect.x,
          y: activity_rect.y
        }

        {:noreply, state} = Events.handle_event(mouse_down_activity, state)
        assert state.selected_activity == 0
        assert state.show_activity_details == true

      _ ->
        :ok
    end
  end
end
