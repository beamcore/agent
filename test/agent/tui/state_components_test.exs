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

    assert event.label == "write lib/foo.ex"
    assert event.status == :done
    refute event.summary =~ content
    refute inspect(event) =~ content
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

    assert StatusBar.widget(state, :wide).text =~ "YOLO"
  end

  test "runtime policy is not bypassed before confirmation" do
    assert {:error, reason} =
             ToolPolicy.allow_tool_call(ToolPolicy.default(), "write", %{
               "filePath" => "scratch/a.ex"
             })

    assert reason =~ "Mutation requires"
  end
end
