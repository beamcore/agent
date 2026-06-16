defmodule Beamcore.TUI.StatusBarTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.Components.StatusBar
  alias Beamcore.TUI.State

  test "status bar exposes F1/F2 switcher" do
    session = %Session{
      roles: %Beamcore.Provider.Selection{
        primary: %{provider: "openai", model: "test-model", enabled: true}
      },
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      last_prompt_tokens: 0
    }

    widget =
      StatusBar.widget(
        %State{
          screen_type: :agent,
          session: session,
          status: :idle,
          spinner_step: 0,
          unicode?: true,
          ctrl_c_pending: false,
          notice: nil
        },
        120
      )

    text = widget.text |> hd() |> Map.fetch!(:spans) |> Enum.map_join(& &1.content)

    assert text =~ "F1 Agent"
    assert text =~ "F2 Chat"
  end

  test "status bar shows retry countdown while waiting" do
    session = %Session{
      roles: %Beamcore.Provider.Selection{
        primary: %{provider: "openai", model: "test-model", enabled: true}
      },
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      last_prompt_tokens: 0
    }

    state =
      %State{
        screen_type: :agent,
        session: session,
        status: :thinking,
        spinner_step: 0,
        unicode?: true,
        ctrl_c_pending: false,
        notice: nil
      }
      |> State.set_wait_status(%{
        reason: :rate_limit,
        wait_ms: 12_000,
        now_ms: System.monotonic_time(:millisecond)
      })

    widget = StatusBar.widget(state, 120)
    text = widget.text |> hd() |> Map.fetch!(:spans) |> Enum.map_join(& &1.content)

    assert text =~ "Rate limited"
    assert text =~ "retrying in"
  end
end
