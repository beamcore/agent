defmodule Beamcore.TUI.State.FactoryTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.State.Factory

  test "does not persist provider readiness as a chat message" do
    state = Factory.new(nil, nil, screen_type: :agent, history: [])

    refute Enum.any?(state.messages, fn message ->
             String.contains?(to_string(message.content), "not configured")
           end)
  end
end
