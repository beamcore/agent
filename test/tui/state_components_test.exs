defmodule Beamcore.TUI.StateComponentsTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.{Context, Session, ToolPolicy}
  alias Beamcore.TUI.Components.{Activity, Chat, Confirmation, EmptyState, Help, Input, StatusBar}
  alias Beamcore.TUI.{Events, State}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })

    config_path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_tui_config_#{System.unique_integer([:positive])}.dets"
      )

    previous_config_path = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, config_path)

    on_exit(fn ->
      restore_config_path(previous_config_path)
      File.rm(config_path)
    end)

    session = Beamcore.OpenAI.client() |> Session.new()
    state = %State{session: session, messages: [], activity: [], status: :idle, unicode?: true}

    %{session: session, state: state}
  end

  test "command palette and help include yolo" do
    command_names = Enum.map(Events.commands(), & &1.name)

    assert "yolo" in command_names
    assert "yolo on" in command_names
    assert "yolo off" in command_names
    assert "policy" in command_names
    assert "policy show" in command_names
    assert "policy init" in command_names
    assert "timeline" in command_names
    assert "timeline last" in command_names
    assert "timeline clear" in command_names
    assert "login" in command_names
    assert "logout" in command_names
    assert "exit" in command_names
    assert "q" in command_names
    refute "confirm" in command_names
    refute "cancel" in command_names
    assert Help.widget().content.text =~ "/yolo"
    assert Help.widget().content.text =~ "/yolo on"
    assert Help.widget().content.text =~ "/yolo off"
    assert Help.widget().content.text =~ "/policy"
    refute Help.widget().content.text =~ "/confirm"
  end

  test "typing slash opens command suggestions" do
    state = input_state("")

    {:noreply, state} = Events.handle_event(key("/"), state)

    assert state.show_commands
    assert Enum.any?(state.command_matches, &(&1.name == "help"))
    assert state.command_selected == 0
  end

  test "/login prompt stores next input without history or transcript leak" do
    state = input_state("/login")

    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)

    assert state.pending_login?
    assert state.history == []
    assert ExRatatui.textarea_get_value(state.textarea) == ""

    ExRatatui.textarea_set_value(state.textarea, "secret-tui-token")
    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)

    refute state.pending_login?
    assert Beamcore.Config.mistral_api_key() == "secret-tui-token"
    assert state.history == []
    assert ExRatatui.textarea_get_value(state.textarea) == ""
    assert Enum.any?(state.messages, &(&1.content == "Beamcore login saved."))
    refute Enum.any?(state.messages, &String.contains?(&1.content, "secret-tui-token"))

    refute Enum.any?(
             state.session.messages,
             &String.contains?(to_string(&1.content), "secret-tui-token")
           )
  end

  test "/login with inline token stores token without input history" do
    state = input_state("/login secret-inline-token")

    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)

    assert Beamcore.Config.mistral_api_key() == "secret-inline-token"
    assert state.history == []
    refute Enum.any?(state.messages, &String.contains?(&1.content, "secret-inline-token"))
  end

  test "state shows friendly configuration message when no token exists" do
    Beamcore.Agent.TestEnv.with_env(%{"MISTRAL_API_KEY" => nil}, fn ->
      state = State.new(nil, ExRatatui.textarea_new(), history: [])

      assert state.session.client == nil
      assert [%{role: :system, content: content}] = state.messages
      assert content =~ "Run /login"
      assert content =~ "MISTRAL_API_KEY"
    end)
  end

  test "slash command suggestions filter yolo commands" do
    state = input_state("") |> type_text("/yo")

    names = Enum.map(state.command_matches, & &1.name)
    assert "yolo" in names
    assert "yolo on" in names
    assert "yolo off" in names
    refute "policy" in names
  end

  test "up down and ctrl navigation move selected command suggestion" do
    state = input_state("") |> type_text("/yo")

    assert state.command_selected == 0

    {:noreply, state} = Events.handle_event(key("down"), state)
    assert state.command_selected == 1

    {:noreply, state} = Events.handle_event(key("n", ["ctrl"]), state)
    assert state.command_selected == 2

    {:noreply, state} = Events.handle_event(key("up"), state)
    assert state.command_selected == 1

    {:noreply, state} = Events.handle_event(key("p", ["ctrl"]), state)
    assert state.command_selected == 0
  end

  test "tab autocompletes selected slash command" do
    state = input_state("") |> type_text("/yo")
    {:noreply, state} = Events.handle_event(key("down"), state)

    {:noreply, state} = Events.handle_event(key("tab"), state)

    refute state.show_commands
    assert ExRatatui.textarea_get_value(state.textarea) == "/yolo on"
  end

  test "esc closes command suggestions" do
    state = input_state("") |> type_text("/yo")

    {:noreply, state} = Events.handle_event(key("esc"), state)

    refute state.show_commands
    assert state.command_matches == []
  end

  test "enter inserts newline and does not accept suggestions while suggestions are open" do
    state = input_state("") |> type_text("/yo")
    {:noreply, state} = Events.handle_event(key("down"), state)

    {:noreply, state} = Events.handle_event(key("enter"), state)

    assert state.show_commands
    assert ExRatatui.textarea_get_value(state.textarea) == "/yo\n"
  end

  test "enter inserts newline and does not send slash command when suggestions are closed" do
    state = input_state("/help")

    {:noreply, state} = Events.handle_event(key("enter"), state)

    refute state.show_help
    value = ExRatatui.textarea_get_value(state.textarea)
    assert value =~ "/help"
    assert value =~ "\n"
  end

  test "enter inserts newline and does not start a turn worker" do
    state = input_state("hello")

    {:noreply, state} = Events.handle_event(key("enter"), state)

    assert state.worker == nil
    assert state.status == :idle
    value = ExRatatui.textarea_get_value(state.textarea)
    assert value =~ "hello"
    assert value =~ "\n"
  end

  test "ctrl+s starts a turn worker and successful completion clears it" do
    state = input_state("hello")

    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)

    assert is_pid(state.worker)
    assert state.status == :thinking
    assert ExRatatui.textarea_get_value(state.textarea) == ""

    assert_receive {:agent_done, pid, session}, 1_000
    assert pid == state.worker

    state = Events.finish_worker(state, session)

    assert state.worker == nil
    assert state.status == :idle
  end

  test "ctrl+enter sends when terminal reports the modifier" do
    state = input_state("hello")

    {:noreply, state} = Events.handle_event(key("enter", ["ctrl"]), state)

    assert is_pid(state.worker)
    assert state.status == :thinking
    assert ExRatatui.textarea_get_value(state.textarea) == ""

    assert_receive {:agent_done, pid, session}, 1_000
    assert pid == state.worker

    state = Events.finish_worker(state, session)

    assert state.worker == nil
    assert state.status == :idle
  end

  test "left and right move cursor and typing inserts at cursor" do
    state = input_state("") |> type_text("abc")

    {:noreply, state} = Events.handle_event(key("left"), state)
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 2}

    {:noreply, state} = Events.handle_event(key("X"), state)
    assert ExRatatui.textarea_get_value(state.textarea) == "abXc"
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 3}

    {:noreply, state} = Events.handle_event(key("right"), state)
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 4}
  end

  test "backspace and delete respect cursor position" do
    state = input_state("") |> type_text("abc")

    {:noreply, state} = Events.handle_event(key("left"), state)
    {:noreply, state} = Events.handle_event(key("backspace"), state)

    assert ExRatatui.textarea_get_value(state.textarea) == "ac"
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 1}

    {:noreply, state} = Events.handle_event(key("delete"), state)

    assert ExRatatui.textarea_get_value(state.textarea) == "a"
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 1}
  end

  test "home and end move cursor within the current input line" do
    state = input_state("") |> type_text("abc")

    {:noreply, state} = Events.handle_event(key("home"), state)
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 0}

    {:noreply, state} = Events.handle_event(key("end"), state)
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 3}
  end

  test "up and down move cursor between multiline input lines" do
    state =
      input_state("")
      |> type_text("ab")
      |> refresh_with_key("enter")
      |> type_text("cd")

    assert ExRatatui.textarea_get_value(state.textarea) == "ab\ncd"
    assert ExRatatui.textarea_cursor(state.textarea) == {1, 2}

    {:noreply, state} = Events.handle_event(key("up"), state)
    assert ExRatatui.textarea_cursor(state.textarea) == {0, 2}

    {:noreply, state} = Events.handle_event(key("X"), state)
    assert ExRatatui.textarea_get_value(state.textarea) == "abX\ncd"

    {:noreply, state} = Events.handle_event(key("down"), state)
    assert ExRatatui.textarea_cursor(state.textarea) == {1, 2}
  end

  test "up and down keep chat scrolling behavior when input is empty", %{state: state} do
    state = %{state | textarea: ExRatatui.textarea_new(), scroll_offset: 0}

    {:noreply, state} = Events.handle_event(key("up"), state)
    assert state.scroll_offset == 1

    {:noreply, state} = Events.handle_event(key("down"), state)
    assert state.scroll_offset == 0
  end

  test "help and input hints describe real command keybindings", %{state: state} do
    help_text = Help.widget().content.text
    input_title = Input.widget(%{state | textarea: ExRatatui.textarea_new()}).block.title

    assert help_text =~ "Enter            Insert newline"
    assert help_text =~ "Ctrl+S           Send"
    assert help_text =~ "Ctrl+Enter       Send if supported by terminal"
    assert help_text =~ "Ctrl+J / Alt+Enter"
    assert help_text =~ "Left/Right       Move cursor"
    assert help_text =~ "Up/Down          Move cursor between input lines"
    assert help_text =~ "Ctrl+P / Ctrl+N  History"
    assert help_text =~ "Tab              Complete highlighted command suggestion"
    assert help_text =~ "/yolo on"
    assert help_text =~ "/yolo off"
    refute help_text =~ "/confirm"

    assert input_title =~ "Ctrl+S send"
    assert input_title =~ "Enter newline"
    assert input_title =~ "arrows move"
    assert input_title =~ "Tab complete"
    assert input_title =~ "/ commands"
  end

  test "timeline details show compact selected activity" do
    state = timeline_state()

    text = Activity.details_text(state)

    assert text =~ "Timeline item 1/2"
    assert text =~ "modify_file (write) lib/a.ex"
    assert text =~ "tool: modify_file"
    assert text =~ "state: done"
    assert text =~ "target: lib/a.ex"
    assert text =~ "output: Wrote file"
    refute text =~ String.duplicate("x", 600)
  end

  test "timeline selection moves up and down while details are open" do
    state = %{timeline_state() | show_activity_details: true}

    {:noreply, state} = Events.handle_event(key("down"), state)
    assert state.selected_activity == 1

    {:noreply, state} = Events.handle_event(key("up"), state)
    assert state.selected_activity == 0

    {:noreply, state} = Events.handle_event(key("down", ["shift"]), state)
    assert state.selected_activity == 1
  end

  test "tab behavior still prioritizes command autocomplete over timeline details" do
    state = input_state("") |> type_text("/ti")

    {:noreply, state} = Events.handle_event(key("tab"), state)

    refute state.show_activity_details
    assert ExRatatui.textarea_get_value(state.textarea) == "/timeline"
  end

  test "esc closes timeline details" do
    state = %{timeline_state() | show_activity_details: true}

    {:noreply, state} = Events.handle_event(key("esc"), state)

    refute state.show_activity_details
  end

  test "timeline slash commands focus latest and clear only UI activity" do
    state = %{timeline_state() | selected_activity: 1}
    ExRatatui.textarea_set_value(state.textarea, "/timeline last")

    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)

    assert state.show_activity_details
    assert state.selected_activity == 0
    assert length(state.activity) == 2

    ExRatatui.textarea_set_value(state.textarea, "/timeline clear")
    {:noreply, state} = Events.handle_event(key("s", ["ctrl"]), state)

    refute state.show_activity_details
    assert state.activity == []

    assert Enum.any?(
             state.messages,
             &String.contains?(&1.content, "Session history was not changed")
           )
  end

  test "empty state is product-facing and professional", %{state: state} do
    widget = state |> EmptyState.text() |> EmptyState.widget()

    assert widget.text =~ "BEAMCORE.AGENT"
    assert widget.text =~ "Tool calls, plans"
    assert widget.text =~ "/help"
    refute widget.text =~ "◢"
    refute widget.text =~ "[b]"
    refute widget.text =~ "%{"
  end

  test "status bar restores compact BeamCore state indicator only", %{state: state} do
    content = state |> StatusBar.widget(:wide) |> paragraph_text()

    assert content =~ "◢▣◣"
    assert content =~ "▱▱▱"

    empty_source = File.read!("lib/tui/components/empty_state.ex")
    header_source = File.read!("lib/tui/render.ex")

    refute empty_source =~ "Mascot"
    refute header_source =~ "Mascot"
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

  test "legacy pending panel renders action details", %{session: session} do
    pending_action = %{
      summary: "Create a module",
      create_files: ["scratch/a.ex"],
      modify_files: ["README.md"],
      delete_files: ["scratch/old.ex"],
      validation: "mix test",
      risks: ["Small scoped change"],
      policy: %{allowed_tools: ["modify_file", "mix"]}
    }

    session = %{
      session
      | pending_user_message: "Create a module",
        context: Context.put_pending_action(session.context, pending_action)
    }

    text = session |> State.pending_action() |> Confirmation.text()

    assert text =~ "Create a module"
    assert text =~ "scratch/a.ex"
    assert text =~ "README.md"
    assert text =~ "mix test"
    refute text =~ "/confirm"
    assert text =~ "/cancel"
  end

  test "activity events are compact and avoid raw payloads", %{state: state} do
    content = String.duplicate("def x, do: :ok\n", 200)

    state =
      state
      |> State.add_activity(
        "modify_file",
        %{"path" => "lib/foo.ex", "content" => content},
        :running
      )
      |> State.update_activity(
        "modify_file",
        %{"path" => "lib/foo.ex", "content" => content},
        "Wrote file"
      )

    [event] = state.activity

    assert event.label == "modify_file (write) lib/foo.ex (3000 bytes)"
    assert event.status == :done
    refute event.summary =~ content
    refute inspect(event) =~ content
  end

  test "activity labels use very-pretty compact tool formatting" do
    cases = [
      {"read", %{"path" => "README.md"}, "read README.md"},
      {"modify_file", %{"path" => "lib/foo.ex", "content" => "abc"}, "modify_file (write) lib/foo.ex (3 bytes)"},
      {"modify_file", %{"path" => "lib/foo.ex", "edits" => [%{"search" => "a", "replace" => "b"}]}, "modify_file (edit) lib/foo.ex (1 edits)"},
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
        "modify_file",
        %{"path" => "scratch/a.ex", "content" => "bad"},
        :blocked,
        "Error: Tool call blocked by project policy."
      )

    assert event.label == "blocked modify_file (write) scratch/a.ex (3 bytes)"
    assert event.status == :blocked
    assert event.result =~ "project policy"
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
        %{"command" => "test", "args" => "test/tui/state_components_test.exs"},
        :running
      )

    assert event.label == "mix test test/tui/state_components_test.exs"
    refute event.label =~ "\e["

    tui_sources =
      "lib/tui/**/*.ex"
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

  test "policy activity event is compact" do
    event =
      State.compact_activity("policy", %{"action" => "deny", "target" => "secrets/**"}, :done)

    assert event.label == "policy deny secrets/**"
    refute event.label =~ "%{"
  end

  test "default runtime policy is autonomous while project policy can still narrow it" do
    assert :ok =
             ToolPolicy.allow_tool_call(ToolPolicy.default(), "modify_file", %{
               "path" => "scratch/a.ex"
             })
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

    # 1. First Ctrl+P key press captures draft and goes to the most recent entry
    up_event = %ExRatatui.Event.Key{code: "p", modifiers: ["ctrl"], kind: "press"}
    {:noreply, state} = Events.handle_event(up_event, state)
    assert state.history_index == 1
    assert state.history_draft == "draft"
    assert ExRatatui.textarea_get_value(state.textarea) == "second"

    # 2. Second Ctrl+P key press goes to the older entry
    {:noreply, state} = Events.handle_event(up_event, state)
    assert state.history_index == 0
    assert ExRatatui.textarea_get_value(state.textarea) == "first"

    # 3. Third Ctrl+P key press stays at the oldest entry (0)
    {:noreply, state} = Events.handle_event(up_event, state)
    assert state.history_index == 0
    assert ExRatatui.textarea_get_value(state.textarea) == "first"

    # 4. Ctrl+N key press goes back to the newer entry (1)
    down_event = %ExRatatui.Event.Key{code: "n", modifiers: ["ctrl"], kind: "press"}
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
    areas =
      Beamcore.TUI.Layout.areas(%ExRatatui.Layout.Rect{
        x: 0,
        y: 0,
        width: 96,
        height: 30
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

    event_opts = [terminal_size: {96, 30}]

    {:noreply, state} = Events.handle_event(mouse_up_chat, state, event_opts)
    assert state.scroll_offset == 3

    # Scroll down over chat
    mouse_down_chat = %ExRatatui.Event.Mouse{
      kind: "scroll_down",
      x: chat_rect.x,
      y: chat_rect.y
    }

    {:noreply, state} = Events.handle_event(mouse_down_chat, state, event_opts)
    assert state.scroll_offset == 0

    # Test scrolling activity if it exists in the layout mode (e.g. :wide or :medium)
    case areas do
      %{activity: activity_rect} ->
        state = %State{
          activity: [
            %{
              id: 1,
              name: "modify_file",
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

        {:noreply, state} = Events.handle_event(mouse_up_activity, state, event_opts)
        assert state.selected_activity == 1
        assert state.show_activity_details == true

        # Scroll down over activity pane -> moves to newer/previous activity item (index 0)
        mouse_down_activity = %ExRatatui.Event.Mouse{
          kind: "scroll_down",
          x: activity_rect.x,
          y: activity_rect.y
        }

        {:noreply, state} = Events.handle_event(mouse_down_activity, state, event_opts)
        assert state.selected_activity == 0
        assert state.show_activity_details == true

      _ ->
        :ok
    end
  end

  defp paragraph_text(%{text: text}) when is_binary(text), do: text

  defp paragraph_text(%{text: lines}) when is_list(lines) do
    lines
    |> Enum.flat_map(&Map.get(&1, :spans, []))
    |> Enum.map_join(& &1.content)
  end

  defp input_state(value) do
    textarea = ExRatatui.textarea_new()
    ExRatatui.textarea_set_value(textarea, value)

    %State{
      textarea: textarea,
      session: Beamcore.OpenAI.client() |> Session.new(),
      messages: [],
      activity: [],
      status: :idle,
      unicode?: true
    }
  end

  defp type_text(state, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(state, fn code, state -> refresh_with_key(state, code) end)
  end

  defp refresh_with_key(state, code) do
    {:noreply, state} = Events.handle_event(key(code), state)
    state
  end

  defp key(code, modifiers \\ []) do
    %ExRatatui.Event.Key{code: code, modifiers: modifiers, kind: "press"}
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)

  defp timeline_state do
    long_result = "Wrote file " <> String.duplicate("x", 700)

    input_state("")
    |> State.update_activity("read", %{"path" => "README.md"}, "Read ok")
    |> State.update_activity(
      "modify_file",
      %{"path" => "lib/a.ex", "content" => "abc"},
      long_result
    )
    |> Map.put(:selected_activity, 0)
  end

  test "Chat.widget renders modify_file tool outputs as a colorized diff" do
    state =
      input_state("")
      |> State.add_message(:tool, "Successfully updated path\n\n-old line\n+new line")

    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 24}
    widget = Chat.widget(state, area)

    assert widget.items != []
    texts = Enum.map(widget.items, fn {paragraph, _height} -> paragraph.text end)
    assert Enum.any?(texts, &String.contains?(&1, "Modify File"))
    assert Enum.any?(texts, &String.contains?(&1, "-old line"))
    assert Enum.any?(texts, &String.contains?(&1, "+new line"))
  end
end
