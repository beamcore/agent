defmodule Beamcore.TUI.StatusBarTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.Components.StatusBar
  alias Beamcore.TUI.State

  defp text(widget) do
    widget.text |> hd() |> Map.fetch!(:spans) |> Enum.map_join(& &1.content)
  end

  defp session do
    %Session{
      roles: %Beamcore.Provider.Selection{
        primary: %{provider: "openai", model: "test-model", enabled: true}
      },
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      last_prompt_tokens: 0
    }
  end

  defp base_state(overrides \\ []) do
    Map.merge(
      %State{
        screen_type: :agent,
        session: session(),
        status: :idle,
        spinner_step: 0,
        unicode?: true,
        ctrl_c_pending: false,
        notice: nil
      },
      Map.new(overrides)
    )
  end

  test "status bar always shows the quit and help hints" do
    text = StatusBar.widget(base_state(), 120) |> text()

    assert text =~ "^C"
    assert text =~ "quit"
    assert text =~ "help"
  end

  test "the quit key hint renders as an accent pill" do
    alias Beamcore.TUI.Theme
    spans = StatusBar.widget(base_state(), 120).text |> hd() |> Map.fetch!(:spans)

    assert Enum.any?(spans, &(&1.content == " ^C " and &1.style == Theme.chip_style()))
  end

  test "status bar no longer renders the F1/F2/F3 switcher (it moved to the mode bar)" do
    text = StatusBar.widget(base_state(), 120) |> text()

    refute text =~ "F1 Agent"
    refute text =~ "F2 Chat"
    refute text =~ "F3 System"
  end

  test "status bar shows retry countdown while waiting" do
    state =
      base_state(status: :thinking)
      |> State.set_wait_status(%{
        reason: :rate_limit,
        wait_ms: 12_000,
        now_ms: System.monotonic_time(:millisecond)
      })

    text = StatusBar.widget(state, 120) |> text()

    assert text =~ "Rate limited"
    assert text =~ "retrying in"
  end

  test "status bar uses cached provider metadata without config lookups" do
    state =
      base_state(session: nil, provider: "cached-provider", model: "cached-model")

    text = StatusBar.widget(state, 120) |> text()

    assert text =~ "cached-provider/cached-model"

    source = File.read!(Path.expand("../../lib/tui/components/status_bar.ex", __DIR__))
    refute source =~ "Beamcore.Config"
    refute source =~ "State.provider"
  end

  test "system screen status bar also shows the hints and no switcher" do
    text = StatusBar.widget(%{screen_type: :system}, 120) |> text()

    assert text =~ "^C"
    assert text =~ "quit"
    assert text =~ "help"
    refute text =~ "F1 Agent"
  end

  test "system screen status bar hints panel navigation, and the Ctrl+C arm when armed" do
    providers = StatusBar.widget(%{screen_type: :system, active_panel: :providers}, 120) |> text()
    assert providers =~ "Tab panel"
    assert providers =~ "select"

    activity = StatusBar.widget(%{screen_type: :system, active_panel: :activity}, 120) |> text()
    assert activity =~ "scroll"

    armed = StatusBar.widget(%{screen_type: :system, ctrl_c_pending: :exit}, 120) |> text()
    assert armed =~ "Press Ctrl+C again to exit"
  end
end
