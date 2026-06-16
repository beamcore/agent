defmodule Beamcore.Agent.Chat.ModeSettingsTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ModeSettings

  setup do
    # Clean up any mode settings from prior tests
    Enum.each(
      [
        :mode_chat_provider,
        :mode_chat_model,
        :mode_agent_provider,
        :mode_agent_model,
        :max_tool_calls,
        :mode_chat_tool_depth_limit,
        :mode_agent_tool_depth_limit
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
          :mode_agent_model,
          :max_tool_calls,
          :mode_chat_tool_depth_limit,
          :mode_agent_tool_depth_limit
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

  test "unknown legacy research screen resolves to agent settings" do
    Beamcore.Config.put(:mode_agent_provider, "openai")
    Beamcore.Config.put(:mode_agent_model, "gpt-test")

    settings = ModeSettings.resolve(:research)

    assert settings.mode == :agent
    assert settings.provider == "openai"
    assert settings.model == "gpt-test"
  end

  test "unknown screen resolves to agent settings" do
    settings = ModeSettings.resolve(:unknown_screen)
    assert settings.mode == :agent
  end

  test "freedom mode does not impose a tiny default tool loop" do
    assert ModeSettings.resolve(:agent).tool_depth_limit == 10_000
    assert ModeSettings.resolve(:chat).tool_depth_limit == 10_000
  end

  test "global tool-call limit is explicit configuration" do
    Beamcore.Config.put(:max_tool_calls, "42")

    assert ModeSettings.resolve(:agent).tool_depth_limit == 42
    assert ModeSettings.resolve(:chat).tool_depth_limit == 42
  end
end
