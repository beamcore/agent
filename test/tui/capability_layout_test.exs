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

  test "chat entrypoint can force TUI" do
    assert Beamcore.Agent.chat(:tui, client: :test_client, tui_start: fn -> :tui_started end) ==
             :tui_started
  end

  test "automatic chat starts TUI" do
    result =
      Beamcore.Agent.chat(:auto,
        supported?: true,
        client: :test_client,
        tui_start: fn -> :tui_started end
      )

    assert result == :tui_started
  end

  test "missing OpenAI API key reports config error without plain fallback" do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_missing_config_#{System.unique_integer([:positive])}.dets"
      )

    previous = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    try do
      Beamcore.Config.set_active_provider("openai")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          result =
            Beamcore.Agent.chat(:auto,
              supported?: true,
              tui_start: fn _opts -> :tui_started end
            )

          send(self(), {:result, result})
        end)

      assert output =~ "Provider 'openai' is not configured"
      assert output =~ "/api add"
      refute output =~ "TUI unavailable"
      refute output =~ "Starting plain emergency fallback"
      refute output =~ "** ("
      assert_receive {:result, :tui_started}
    after
      restore_config_path(previous)
      File.rm(path)
    end
  end

  test "layout mode selection covers wide, medium, narrow, and tiny" do
    assert Layout.mode(140, 40) == :wide
    assert Layout.mode(100, 30) == :medium
    assert Layout.mode(80, 24) == :narrow
    assert Layout.mode(40, 9) == :tiny
  end

  test "layout areas adapt by mode" do
    assert %{mode: :wide, chat: %Rect{}, input: %Rect{}, status: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 140, height: 36})

    assert %{mode: :medium, chat: %Rect{}, input: %Rect{}, status: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 100, height: 30})

    assert %{mode: :narrow, chat: %Rect{}, input: %Rect{}, status: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 80, height: 24})

    assert %{mode: :tiny, screen: %Rect{}} =
             Layout.areas(%Rect{x: 0, y: 0, width: 40, height: 9})
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end
