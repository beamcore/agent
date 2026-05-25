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
    assert "policy" in command_names
    assert "policy show" in command_names
    assert "policy init" in command_names
    refute "confirm" in command_names
    refute "cancel" in command_names
    assert Help.widget().content.text =~ "/yolo"
    assert Help.widget().content.text =~ "/policy"
    refute Help.widget().content.text =~ "/confirm"
  end

  test "empty state is product-facing and includes mascot hints", %{state: state} do
    widget = state |> EmptyState.text() |> EmptyState.widget()

    assert widget.text =~ "BEAMCORE.AGENT"
    assert widget.text =~ "Tool calls, plans"
    assert widget.text =~ "/help"
    refute widget.text =~ "%{"
  end

  test "mascot has terminal-safe animation frames" do
    assert Mascot.frame(0, true) != Mascot.frame(1, true)
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

  test "scroll offset is clamped and new messages do not yank user from history", %{state: state} do
    scrolled = State.scroll_up(state, 500)
    assert scrolled.scroll_offset == 120

    still_scrolled = State.add_message(scrolled, :assistant, "new message while reading history")
    assert still_scrolled.scroll_offset == 120

    bottom = State.scroll_down(still_scrolled, 500)
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
      policy: %{allowed_tools: ["write", "mix"]}
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
        "Error: Tool call blocked by project policy."
      )

    assert event.label == "blocked write scratch/a.ex (3 bytes)"
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

  test "status bar reflects autonomous yolo default", %{state: state} do
    assert StatusBar.widget(state, :wide).text =~ "YOLO"
  end

  test "status bar includes project policy indicator", %{state: state} do
    assert StatusBar.widget(state, :wide).text =~ "policy:"
  end

  test "policy activity event is compact" do
    event =
      State.compact_activity("policy", %{"action" => "deny", "target" => "secrets/**"}, :done)

    assert event.label == "policy deny secrets/**"
    refute event.label =~ "%{"
  end

  test "default runtime policy is autonomous while project policy can still narrow it" do
    assert :ok =
             ToolPolicy.allow_tool_call(ToolPolicy.default(), "write", %{
               "filePath" => "scratch/a.ex"
             })
  end
end
