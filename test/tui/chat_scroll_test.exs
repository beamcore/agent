defmodule Beamcore.TUI.ChatScrollTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.Components.Chat
  alias Beamcore.TUI.{Events, State}
  alias ExRatatui.Layout.Rect

  setup do
    Beamcore.Config.put_provider("openai", %{
      api_key: "test-api-key",
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o"
    })

    Beamcore.Config.set_active_provider("openai")

    session_id = "tui-chatscroll-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), session_id)
    File.mkdir_p!(tmp_dir)

    session =
      Beamcore.Provider.Registry.client()
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

  test "long chat visible window remains bounded near the tail" do
    messages =
      Enum.map(1..5_000, fn index ->
        %{role: :assistant, content: "message #{index} " <> String.duplicate("body ", 12)}
      end)

    {visible, bottom_spacer, effective_offset} =
      Chat.visible_message_window(messages, 80, 20, 0)

    assert length(visible) < 80
    assert List.last(visible).content =~ "message 5000"
    assert bottom_spacer == 0
    assert effective_offset == 0
  end

  test "long chat visible window follows scroll offset without rendering full history" do
    messages =
      Enum.map(1..5_000, fn index ->
        %{role: :assistant, content: "message #{index} " <> String.duplicate("body ", 12)}
      end)

    {tail_visible, _tail_spacer, _tail_offset} =
      Chat.visible_message_window(messages, 80, 20, 0)

    {scrolled_visible, bottom_spacer, effective_offset} =
      Chat.visible_message_window(messages, 80, 20, 400)

    assert length(scrolled_visible) < 120
    assert bottom_spacer > 0
    assert effective_offset == 400
    refute List.first(scrolled_visible).content == List.first(tail_visible).content
  end

  test "visible window clamps an oversized scroll offset to existing history" do
    messages =
      Enum.map(1..20, fn index ->
        %{role: :assistant, content: "message #{index}"}
      end)

    {visible, _bottom_spacer, effective_offset} =
      Chat.visible_message_window(messages, 80, 10, 100_000)

    assert visible != []
    assert List.first(visible).content =~ "message 1"
    assert effective_offset < 100_000
  end

  test "chat widget renders bounded items for thousands of messages", %{state: state} do
    messages =
      Enum.map(1..5_000, fn index ->
        %{role: :assistant, content: "message #{index} " <> String.duplicate("body ", 12)}
      end)

    state = %{state | messages: messages}
    widget = Chat.widget(state, %Rect{x: 0, y: 0, width: 100, height: 24})

    assert length(widget.items) < 100
  end
end
