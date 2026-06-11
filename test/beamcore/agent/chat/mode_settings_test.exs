defmodule Beamcore.Agent.Chat.ModeSettingsTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ModeSettings

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "BEAMCORE_CHAT_PROVIDER" => nil,
      "BEAMCORE_CHAT_MODEL" => nil,
      "BEAMCORE_AGENT_PROVIDER" => nil,
      "BEAMCORE_AGENT_MODEL" => nil
    })
  end

  test "resolves F2 chat provider and model from environment" do
    Beamcore.Agent.TestEnv.with_env(
      %{
        "BEAMCORE_CHAT_PROVIDER" => "openai",
        "BEAMCORE_CHAT_MODEL" => "gpt-test"
      },
      fn ->
        settings = ModeSettings.resolve(:chat)

        assert settings.mode == :chat
        assert settings.provider == "openai"
        assert settings.model == "gpt-test"
      end
    )
  end

  test "unknown legacy research screen resolves to agent settings" do
    Beamcore.Agent.TestEnv.with_env(
      %{
        "BEAMCORE_AGENT_PROVIDER" => "openai",
        "BEAMCORE_AGENT_MODEL" => "gpt-test"
      },
      fn ->
        settings = ModeSettings.resolve(:research)

        assert settings.mode == :agent
        assert settings.provider == "openai"
        assert settings.model == "gpt-test"
      end
    )
  end

  test "unknown screen resolves to agent settings" do
    settings = ModeSettings.resolve(:unknown_screen)
    assert settings.mode == :agent
  end
end
