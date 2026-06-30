defmodule Beamcore.TUI.Components.InputThrobberTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.Input

  defp state(overrides) do
    Map.merge(
      %{textarea: ExRatatui.textarea_new(), status: :idle, spinner_step: 0, unicode?: true},
      Map.new(overrides)
    )
  end

  defp title(state), do: Input.widget(state).block.title

  test "shows the static composer hint when idle" do
    assert title(state(status: :idle)) =~ "Ctrl+s send"
  end

  test "shows a spinner and the status word while the agent is working" do
    text = title(state(status: :thinking))
    assert text =~ "thinking"
    refute text =~ "Ctrl+s send"
  end

  test "the spinner glyph advances with the spinner step" do
    refute title(state(status: :thinking, spinner_step: 0)) ==
             title(state(status: :thinking, spinner_step: 1))
  end

  test "tool_running and rate_limited also show a working indicator" do
    assert title(state(status: :tool_running)) =~ "tool"
    assert title(state(status: :rate_limited)) =~ "rate limited"
  end

  test "falls back to an ASCII spinner when unicode is unavailable" do
    text = title(state(status: :thinking, unicode?: false))
    assert String.contains?(text, ["|", "/", "-", "\\"])
  end
end
