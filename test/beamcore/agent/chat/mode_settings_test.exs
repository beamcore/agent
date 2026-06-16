defmodule Beamcore.Agent.Chat.ModeSettingsTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ModeSettings

  setup do
    Enum.each(
      [
        :mode_chat_provider,
        :mode_chat_model,
        :mode_agent_provider,
        :mode_agent_model
      ],
      fn key ->
        Beamcore.Config.delete(key)
      end
    )

    Beamcore.Config.set_active_provider("openai")

    on_exit(fn ->
      Enum.each(
        [
          :mode_chat_provider,
          :mode_chat_model,
          :mode_agent_provider,
          :mode_agent_model
        ],
        fn key ->
          Beamcore.Config.delete(key)
        end
      )
    end)
  end

  test "resolves F2 chat provider and model from Config" do
    Beamcore.Config.put(:mode_chat_provider, "openai")
    Beamcore.Config.put(:mode_chat_model, "gpt-test")

    settings = ModeSettings.resolve(:chat)

    assert settings.mode == :chat
    assert settings.provider == "openai"
    assert settings.model == "gpt-test"
  end

  test "unknown mode raises ArgumentError" do
    assert_raise ArgumentError, ~r/Unknown mode/, fn ->
      ModeSettings.resolve(:unknown_screen)
    end
  end

  test "retry_limit defaults differ by mode" do
    Beamcore.Config.put(:mode_agent_provider, "openai")
    Beamcore.Config.put(:mode_agent_model, "gpt-test")
    Beamcore.Config.put(:mode_chat_provider, "openai")
    Beamcore.Config.put(:mode_chat_model, "gpt-test")

    assert ModeSettings.resolve(:agent).retry_limit == 3
    assert ModeSettings.resolve(:chat).retry_limit == 2
  end
end
