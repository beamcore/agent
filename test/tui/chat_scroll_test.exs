defmodule Beamcore.TUI.ChatScrollTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.{Events, State}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{"MISTRAL_API_KEY" => "test-api-key"})
    session_id = "tui-chatscroll-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), session_id)
    File.mkdir_p!(tmp_dir)

    session =
      Beamcore.OpenAI.client()
      |> Session.new(session_id: session_id, screen_type: :chat)
      |> Map.put(:state_file, Path.join(tmp_dir, "session.state.json"))
      |> Map.put(:checkpoint_file, Path.join(tmp_dir, "session.checkpoints.json"))

    state = %State{
      textarea: ExRatatui.textarea_new(),
      session: session,
      messages: [],
      activity: [],
      status: :idle,
      unicode?: true,
      screen_type: :chat,
      chat_viewport_height: 20
    }

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{state: state}
  end

  defp key(code, mods \\ []) do
    %ExRatatui.Event.Key{code: code, modifiers: mods, kind: :press}
  end

  test "PgUp scrolls chat history up by a page", %{state: state} do
    {:noreply, scrolled} = Events.handle_event(key("page_up"), state)
    assert scrolled.scroll_offset == 18
  end

  test "PgDn scrolls back toward the latest, clamped at zero", %{state: state} do
    {:noreply, scrolled} = Events.handle_event(key("page_up"), state)
    {:noreply, back} = Events.handle_event(key("page_down"), scrolled)
    assert back.scroll_offset == 0
  end

  test "PgUp pages chat even when the composer has text", %{state: state} do
    ExRatatui.textarea_set_value(state.textarea, "a half-typed message")
    {:noreply, scrolled} = Events.handle_event(key("page_up"), state)
    assert scrolled.scroll_offset == 18
  end

  test "PgUp pages the activity timeline when it is focused", %{state: state} do
    state = %{state | activity_focused?: true, activity_viewport_height: 10}
    {:noreply, scrolled} = Events.handle_event(key("page_up"), state)
    # Chat offset is untouched; activity handler took precedence.
    assert scrolled.scroll_offset == 0
  end
end
