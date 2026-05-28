defmodule Beamcore.TUI.CapabilityLayoutTest do
  use ExUnit.Case

  alias Beamcore.TUI.Layout
  alias ExRatatui.Layout.Rect

  test "chat entrypoint selects TUI when supported" do
    assert Beamcore.Agent.chat_mode(supported?: true) == :tui
  end

  test "ordinary development terminal sizes do not force plain fallback" do
    assert Beamcore.Agent.chat_mode(
             interactive?: true,
             term: "xterm-256color",
             terminal_size: {80, 24}
           ) == :tui
  end

  test "chat entrypoint can force TUI and plain fallback" do
    assert Beamcore.Agent.chat(:tui, tui_start: fn -> :tui_started end) == :tui_started
    assert Beamcore.Agent.chat(:plain, plain_start: fn -> :plain_started end) == :plain_started
  end

  test "automatic chat falls back if TUI startup fails" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        result =
          Beamcore.Agent.chat(:auto,
            supported?: true,
            tui_start: fn -> raise "alternate screen failed" end,
            plain_start: fn -> :plain_started end
          )

        send(self(), {:result, result})
      end)

    assert output =~ "TUI unavailable"
    assert output =~ "Starting plain emergency fallback"
    assert_receive {:result, :plain_started}
  end

  test "layout mode selection covers wide, medium, narrow, and tiny" do
    assert Layout.mode(140, 40) == :wide
    assert Layout.mode(100, 30) == :medium
    assert Layout.mode(80, 24) == :narrow
    assert Layout.mode(40, 9) == :tiny
  end

  test "layout areas adapt by mode" do
    assert %{mode: :wide, activity: %Rect{}, chat: %Rect{}, input: %Rect{}, status: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 140, height: 36})

    assert %{mode: :medium, activity: %Rect{}, chat: %Rect{}, input: %Rect{}, status: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 100, height: 30})

    assert %{mode: :narrow, chat: %Rect{}, input: %Rect{}, status: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 80, height: 24})

    assert %{mode: :tiny, screen: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 40, height: 9})
  end
end
