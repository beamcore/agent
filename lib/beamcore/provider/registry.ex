defmodule Beamcore.Provider.Registry do
  @moduledoc """
  Provider registry and capability mapping.

  This module keeps provider-specific defaults and diagnostics out of TUI and
  orchestration code. It performs no network calls; reachability checks belong
  in supervised provider health probes.
  """

  alias Beamcore.Provider.{Capabilities, Error, Model}
  alias Beamcore.Provider.Adapters.OpenAICompatible

  @defaults %{
    "mistral" => %{
      id: :mistral,
      adapter: OpenAICompatible,
      base_url: "https://api.mistral.ai/v1",
      auth: :bearer,
      secret_envs: ["MISTRAL_API_KEY", "API_KEY"],
      legacy_secret: :mistral,
      default_model: "mistral-medium-3-5",
      requires_api_key?: true,
      local?: false,
      default_primary?: true
    },
    "ollama" => %{
      id: :ollama,
      adapter: OpenAICompatible,
      base_url: "http://127.0.0.1:11434/v1",
      auth: :none,
      secret_envs: [],
      default_model: "gemma4:latest",
      requires_api_key?: false,
      local?: true,
      discovery: Beamcore.Provider.OllamaDiscovery
    },
    "openai" => %{
      id: :openai,
      adapter: OpenAICompatible,
      base_url: "https://api.openai.com/v1",
      auth: :bearer,
      secret_envs: ["OPENAI_API_KEY", "API_KEY"],
      default_model: "gpt-4o",
      requires_api_key?: true,
      local?: false
    },
    "deepseek" => %{
      id: :deepseek,
      adapter: OpenAICompatible,
      base_url: "https://api.deepseek.com/v1",
      auth: :bearer,
      secret_envs: ["DEEPSEEK_API_KEY", "API_KEY"],
      default_model: "deepseek-chat",
      requires_api_key?: true,
      local?: false
    }
  }

  @type provider_info :: %{
          name: binary(),
          id: atom(),
          adapter: module(),
          config: map() | nil,
          default_config: map(),
          active?: boolean(),
          configured?: boolean(),
          requires_api_key?: boolean(),
          auth: atom(),
          base_url: binary() | nil,
          default_model: binary() | nil,
          capabilities: Capabilities.t(),
          discovery: module() | nil,
          reachable?: :unknown
        }

  def defaults, do: @defaults

  @spec list() :: [provider_info()]
  def list do
    custom = Beamcore.Config.list_providers()
    active = Beamcore.Config.active_provider()

    @defaults
    |> Map.keys()
    |> Kernel.++(Map.keys(custom))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      config = Map.get(custom, name)
      default = Map.get(@defaults, name, custom_default(name))
      merged = merge_config(default, config)
      model = Map.get(merged, "default_model") || Map.get(merged, :default_model)

      %{
        name: name,
        id: Map.fetch!(default, :id),
        adapter: Map.fetch!(default, :adapter),
        config: config,
        default_config: default,
        active?: name == active,
        configured?: configured?(name, config, default),
        requires_api_key?: Map.get(default, :requires_api_key?, true),
        auth: Map.get(default, :auth, :bearer),
        base_url: Map.get(merged, "base_url") || Map.get(merged, :base_url),
        default_model: model,
        capabilities: capabilities(name, model),
        discovery: Map.get(default, :discovery),
        reachable?: :unknown
      }
    end)
  end

  def get(name) when is_binary(name), do: Enum.find(list(), &(&1.name == name))

  def provider_requires_key?(name) when is_binary(name) do
    case get(name) do
      nil -> true
      provider -> provider.requires_api_key?
    end
  end

  def missing_config_message(name \\ Beamcore.Config.active_provider()) do
    case get(name) do
      nil ->
        "Unknown provider '#{name}'. Open Ctrl+O or run /api list to choose a configured provider."

      %{requires_api_key?: true} ->
        legacy = if name == "mistral", do: " You may also use /login for the legacy Mistral credential flow.", else: ""

        "Provider '#{name}' is not configured. Use Ctrl+O or /api add #{name} <token> [<base_url>] [<model>].#{legacy}"

      _provider ->
        "Provider '#{name}' is unavailable. Check its endpoint/model configuration with Ctrl+O or /api list."
    end
  end

  def default_primary_provider_name do
    default_provider_name(:default_primary?) || "mistral"
  end

  def resolve_api_key(%{auth: :none}), do: nil
  def resolve_api_key(%{auth: "none"}), do: nil

  def resolve_api_key(%{config: %{"api_key" => key}}) when is_binary(key),
    do: Beamcore.Config.decrypted_api_key(key)

  def resolve_api_key(%{default_config: default}) do
    legacy_secret_value(default) || env_secret_value(default)
  end

  def validate_selection(name) when is_binary(name) do
    case get(name) do
      nil ->
        {:error,
         Error.exception(
           provider: nil,
           kind: :invalid_config,
           message: "Unknown provider #{name}"
         )}

      %{requires_api_key?: true, configured?: false, id: id} ->
        {:error,
         Error.exception(
           provider: id,
           kind: :missing_config,
           message: "Provider #{name} requires an API key."
         )}

      provider ->
        {:ok, provider}
    end
  end

  @spec models(binary()) :: [Model.t()]
  def models(provider_name) do
    case get(provider_name) do
      nil ->
        []

      %{discovery: discovery} = provider when is_atom(discovery) ->
        case Beamcore.Provider.Health.list_models(provider_name) do
          {:ok, models} ->
            Enum.map(models, fn model ->
              %Model{id: model, name: model, capabilities: provider.capabilities}
            end)

          _ ->
            []
        end

      %{default_model: model, capabilities: caps} when is_binary(model) ->
        [%Model{id: model, name: model, capabilities: caps}]

      _provider ->
        []
    end
  end

  @spec capabilities(binary(), binary() | nil) :: Capabilities.t()
  def capabilities(provider_name, model \\ nil)

  def capabilities("ollama", _model) do
    %Capabilities{
      chat: true,
      streaming: true,
      tool_calls: true,
      structured_output: true,
      local: true,
      context_window: nil,
      latency_class: :low
    }
  end

  def capabilities("mistral", _model) do
    %Capabilities{
      chat: true,
      streaming: false,
      tool_calls: true,
      parallel_tool_calls: true,
      structured_output: true,
      context_window: 128_000,
      latency_class: :medium,
      token_accounting: true,
      retry_after: true
    }
  end

  def capabilities("openai", _model) do
    %Capabilities{
      chat: true,
      streaming: false,
      tool_calls: true,
      parallel_tool_calls: true,
      structured_output: true,
      vision: true,
      context_window: 128_000,
      latency_class: :medium,
      token_accounting: true,
      retry_after: true
    }
  end

  def capabilities(_provider_name, _model) do
    %Capabilities{
      chat: true,
      streaming: false,
      tool_calls: true,
      structured_output: true,
      latency_class: :unknown,
      retry_after: true
    }
  end

  defp custom_default(name) do
    %{
      id: :openai_compatible,
      adapter: OpenAICompatible,
      base_url: nil,
      auth: :bearer,
      secret_envs: [provider_env_key(name), "API_KEY"],
      default_model: nil,
      requires_api_key?: true,
      local?: false
    }
  end

  defp default_provider_name(flag) do
    @defaults
    |> Enum.find_value(fn {name, config} ->
      if Map.get(config, flag), do: name
    end)
  end

  defp merge_config(default, nil) do
    %{
      "base_url" => Map.get(default, :base_url),
      "default_model" => Map.get(default, :default_model),
      "api_key" => nil
    }
  end

  defp merge_config(default, config) when is_map(config) do
    %{
      "base_url" => Map.get(config, "base_url") || Map.get(default, :base_url),
      "default_model" => Map.get(config, "default_model") || Map.get(default, :default_model),
      "api_key" => Map.get(config, "api_key")
    }
  end

  defp configured?(_name, _config, %{requires_api_key?: false}), do: true

  defp configured?(_name, config, default) do
    (is_map(config) and is_binary(Map.get(config, "api_key"))) ||
      is_binary(legacy_secret_value(default)) ||
      is_binary(env_secret_value(default))
  end

  defp legacy_secret_value(%{legacy_secret: :mistral}),
    do: Beamcore.Config.mistral_api_key()

  defp legacy_secret_value(_default), do: nil

  defp env_secret_value(default) do
    default
    |> Map.get(:secret_envs, [])
    |> Enum.find_value(&System.get_env/1)
  end

  defp provider_env_key(name) do
    normalized =
      name
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]+/, "_")
      |> String.trim("_")

    "#{normalized}_API_KEY"
  end

end
