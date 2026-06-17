defmodule Beamcore.TUI.PasteTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.{Events, State}

  setup do
    Beamcore.Config.put_provider("openai", %{
      api_key: "test-api-key",
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o"
    })

    Beamcore.Config.set_active_provider("openai")

    session_id = "tui-paste-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), session_id)
    File.mkdir_p!(tmp_dir)

    session =
      Beamcore.Provider.Registry.client()
      |> Session.new(session_id: session_id, screen_type: :chat)
      |> Map.put(:checkpoint_file, Path.join(tmp_dir, "session.checkpoints.json"))

    state = %State{
      textarea: ExRatatui.textarea_new(),
      session: session,
      messages: [],
      activity: [],
      status: :idle,
      unicode?: true,
      screen_type: :chat
    }

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{state: state}
  end

  defp paste(content), do: %{type: :paste, content: content}

  test "bracketed paste inserts the full payload into the composer", %{state: state} do
    {:noreply, state} = Events.handle_event(paste("hello world"), state)
    assert ExRatatui.textarea_get_value(state.textarea) == "hello world"
  end

  test "multi-line paste preserves newlines rather than sending", %{state: state} do
    {:noreply, state} = Events.handle_event(paste("line one\nline two\nline three"), state)
    assert ExRatatui.textarea_get_value(state.textarea) == "line one\nline two\nline three"
    refute state.status == :thinking
  end

  test "paste does not interpret a leading slash as a command submission", %{state: state} do
    {:noreply, state} = Events.handle_event(paste("/not a command"), state)
    assert ExRatatui.textarea_get_value(state.textarea) == "/not a command"
  end
end
