defmodule Beamcore.Agent.Chat.ModeSettingsTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ModeSettings

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "BEAMCORE_CHAT_PROVIDER" => nil,
      "BEAMCORE_CHAT_MODEL" => nil,
      "BEAMCORE_RESEARCH_PROVIDER" => nil,
      "BEAMCORE_RESEARCH_MODEL" => nil,
      "BEAMCORE_DEEP_RESEARCH_PROVIDER" => nil,
      "BEAMCORE_DEEP_RESEARCH_MODEL" => nil,
      "BEAMCORE_RESEARCH_INPUT_BUDGET" => nil
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

  test "resolves F3 research provider and model from environment with budget override" do
    Beamcore.Agent.TestEnv.with_env(
      %{
        "BEAMCORE_RESEARCH_PROVIDER" => "ollama",
        "BEAMCORE_RESEARCH_MODEL" => "gemma-test",
        "BEAMCORE_RESEARCH_INPUT_BUDGET" => "1234"
      },
      fn ->
        settings = ModeSettings.resolve(:research)

        assert settings.mode == :research
        assert settings.provider == "ollama"
        assert settings.model == "gemma-test"
        assert settings.input_budget == 1234
      end
    )
  end

  test "resolves deep research as its own configurable mode" do
    Beamcore.Agent.TestEnv.with_env(
      %{
        "BEAMCORE_DEEP_RESEARCH_PROVIDER" => "ollama",
        "BEAMCORE_DEEP_RESEARCH_MODEL" => "local-research"
      },
      fn ->
        settings = ModeSettings.resolve(:deep_research)

        assert settings.mode == :deep_research
        assert settings.provider == "ollama"
        assert settings.model == "local-research"
      end
    )
  end
end
