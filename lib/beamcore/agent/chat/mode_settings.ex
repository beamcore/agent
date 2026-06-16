defmodule Beamcore.Agent.Chat.ModeSettings do
  @moduledoc """
  Resolves per-mode provider, model, and execution limits.

  Settings are stored in `Beamcore.Config` (DETS-backed). Each mode
  (`:agent`, `:chat`) has its own set of keys. Falls back to built-in
  defaults when no stored value exists.
  """

  @enforce_keys [:mode, :provider, :model]
  defstruct mode: :agent,
            provider: nil,
            model: nil,
            input_budget: 32_000,
            output_budget: 4_000,
            history_limit: 304,
            tool_depth_limit: 10_000,
            retry_limit: 3

  @default_tool_depth_limit 10_000

  @defaults %{
    agent: %{
      input_budget: 32_000,
      output_budget: 4_000,
      history_limit: 304,
      tool_depth_limit: @default_tool_depth_limit,
      retry_limit: 3
    },
    chat: %{
      input_budget: 16_000,
      output_budget: 2_000,
      history_limit: 120,
      tool_depth_limit: @default_tool_depth_limit,
      retry_limit: 2
    }
  }

  @doc """
  Resolve settings for a screen/mode.
  """
  def resolve(mode) do
    mode = normalize_mode(mode)
    defaults = Map.fetch!(@defaults, mode)

    provider =
      Beamcore.Config.get(:"mode_#{mode}_provider") ||
        Beamcore.Config.active_provider(mode)

    model =
      Beamcore.Config.get(:"mode_#{mode}_model") ||
        Beamcore.Config.active_model(mode)

    %__MODULE__{
      mode: mode,
      provider: provider,
      model: model,
      input_budget: config_integer(:"mode_#{mode}_input_budget", defaults.input_budget),
      output_budget: config_integer(:"mode_#{mode}_output_budget", defaults.output_budget),
      history_limit: config_integer(:"mode_#{mode}_history_limit", defaults.history_limit),
      tool_depth_limit: tool_depth_limit(mode, defaults.tool_depth_limit),
      retry_limit: config_integer(:"mode_#{mode}_retry_limit", defaults.retry_limit)
    }
  end

  def normalize_mode(nil), do: :agent
  def normalize_mode(:f1), do: :agent
  def normalize_mode(:f2), do: :chat
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

  defp config_integer(key, default) do
    case Beamcore.Config.get_setting(key) do
      nil -> default
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp tool_depth_limit(mode, default) do
    config_integer(:max_tool_calls, nil) ||
      config_integer(:"mode_#{mode}_tool_depth_limit", default)
  end
end
