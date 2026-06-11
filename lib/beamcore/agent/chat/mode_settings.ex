defmodule Beamcore.Agent.Chat.ModeSettings do
  @moduledoc """
  Resolves per-mode provider, model, and execution limits.

  Environment variables use the normalized mode name:

  - `BEAMCORE_AGENT_PROVIDER`, `BEAMCORE_AGENT_MODEL`
  - `BEAMCORE_CHAT_PROVIDER`, `BEAMCORE_CHAT_MODEL`
  Stored provider/model selections from `Beamcore.Config` are used when the
  environment does not override them.
  """

  @enforce_keys [:mode, :provider, :model]
  defstruct mode: :agent,
            provider: nil,
            model: nil,
            input_budget: 32_000,
            output_budget: 4_000,
            history_limit: 304,
            tool_depth_limit: 100,
            retry_limit: 3

  @defaults %{
    agent: %{
      input_budget: 32_000,
      output_budget: 4_000,
      history_limit: 304,
      tool_depth_limit: 80,
      retry_limit: 3
    },
    chat: %{
      input_budget: 16_000,
      output_budget: 2_000,
      history_limit: 120,
      tool_depth_limit: 2,
      retry_limit: 2
    }
  }

  @mode_env %{
    agent: "AGENT",
    chat: "CHAT"
  }

  @doc """
  Resolve settings for a screen/mode.
  """
  def resolve(mode) do
    mode = normalize_mode(mode)
    defaults = Map.fetch!(@defaults, mode)

    provider =
      env_value(mode, "PROVIDER") ||
        Beamcore.Config.active_provider(mode)

    model =
      env_value(mode, "MODEL") ||
        Beamcore.Config.active_model(mode)

    %__MODULE__{
      mode: mode,
      provider: provider,
      model: model,
      input_budget: integer_setting(mode, "INPUT_BUDGET", defaults.input_budget),
      output_budget: integer_setting(mode, "OUTPUT_BUDGET", defaults.output_budget),
      history_limit: integer_setting(mode, "HISTORY_LIMIT", defaults.history_limit),
      tool_depth_limit: integer_setting(mode, "TOOL_DEPTH_LIMIT", defaults.tool_depth_limit),
      retry_limit: integer_setting(mode, "RETRY_LIMIT", defaults.retry_limit)
    }
  end

  def normalize_mode(nil), do: :agent
  def normalize_mode(:f1), do: :agent
  def normalize_mode(:f2), do: :chat
  def normalize_mode(:f3), do: :agent
  def normalize_mode(mode) when mode in [:agent, :chat], do: mode

  def normalize_mode(mode) when is_binary(mode) do
    case mode do
      "agent" -> :agent
      "chat" -> :chat
      _ -> :agent
    end
  end

  def normalize_mode(_mode), do: :agent

  def local_provider?(%__MODULE__{provider: provider}) do
    case Beamcore.Provider.Registry.get(provider) do
      %{capabilities: %{local: true}} -> true
      _ -> false
    end
  end

  defp env_value(mode, suffix) do
    key = "BEAMCORE_#{Map.fetch!(@mode_env, mode)}_#{suffix}"

    case System.get_env(key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp integer_setting(mode, suffix, default) do
    case env_value(mode, suffix) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _ -> default
        end
    end
  end
end
