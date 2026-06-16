defmodule Beamcore.Agent.Chat.ModeSettings do
  @moduledoc """
  Resolves per-mode provider, model, and retry limits.

  Settings are stored in `Beamcore.Config` (DETS-backed). Each mode
  (`:agent`, `:chat`) has its own set of keys. Falls back to built-in
  defaults when no stored value exists.
  """

  @enforce_keys [:mode, :provider, :model]
  defstruct mode: :agent,
            provider: nil,
            model: nil,
            retry_limit: 3

  @defaults %{
    agent: %{retry_limit: 3},
    chat: %{retry_limit: 2}
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
      other -> raise ArgumentError, "Unknown mode: #{inspect(other)}"
    end
  end

  def normalize_mode(mode) do
    raise ArgumentError, "Unknown mode: #{inspect(mode)}"
  end

  defp config_integer(key, default) do
    case Beamcore.Config.get_setting(key) do
      nil -> default
      value when is_integer(value) -> value
      _ -> default
    end
  end
end
