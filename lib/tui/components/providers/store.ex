defmodule Beamcore.TUI.Components.Providers.Store do
  @moduledoc false

  def load do
    Beamcore.Config.list_providers() |> Enum.sort() |> Enum.to_list()
  end

  def delete(name) do
    providers = Beamcore.Config.list_providers()
    configs = Map.delete(providers, name)
    Beamcore.Config.put(:api_configs, Jason.encode!(configs))
  end

  def activate(name, config, screen_type) do
    model = Map.get(config, "default_model") || Beamcore.Agent.Chat.API.default_model()
    Beamcore.Config.set_active_provider(screen_type, name)
    Beamcore.Config.set_active_model(screen_type, model)
  end

  def active(screen_type) do
    Beamcore.Config.active_provider(screen_type)
  end
end
