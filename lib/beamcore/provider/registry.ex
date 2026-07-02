defmodule Beamcore.Provider.Registry do
  @moduledoc """
  Provider registry and capability mapping.

  This module keeps provider-specific defaults and diagnostics out of TUI and
  orchestration code. It performs no network calls; reachability checks belong
  in supervised provider health probes.
  """

  alias Beamcore.Provider.{Auth, Capabilities, Error, Model}
  alias Beamcore.Provider.Adapters.OpenAICompatible

  @defaults %{
    "openai" => %{
      id: :openai,
      adapter: OpenAICompatible,
      base_url: "https://api.openai.com/v1",
      auth: :bearer,
      default_model: "gpt-4o",
      requires_api_key?: true,
      local?: false
    },
    "deepseek" => %{
      id: :deepseek,
      adapter: OpenAICompatible,
      base_url: "https://api.deepseek.com/v1",
      auth: :bearer,
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
      default = Map.get(@defaults, name, custom_default(name, config))
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
        auth:
          Map.get(merged, "auth") || Map.get(merged, :auth) || Map.get(default, :auth, :bearer),
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
        "Unknown provider '#{name}'. Run /api list to choose a configured provider."

      %{requires_api_key?: true} ->
        "Provider '#{name}' is not configured. Use /api add #{name} <token> [<base_url>] [<model>]."

      _provider ->
        "Provider '#{name}' is unavailable. Check its endpoint/model configuration with /api list."
    end
  end

  def default_primary_provider_name do
    default_provider_name(:default_primary?)
  end

  def resolve_api_key(%{auth: :none}), do: nil
  def resolve_api_key(%{auth: "none"}), do: nil

  def resolve_api_key(%{config: %{"api_key" => key}}) when is_binary(key) do
    Beamcore.Config.decrypted_api_key(key)
  end

  def resolve_api_key(_provider_info), do: nil

  @doc """
  Returns an OpenaiEx client for the active provider.

  Raises if the active provider is not configured.
  """
  def client do
    provider_name = Beamcore.Config.active_provider()

    case validate_selection(provider_name) do
      {:ok, provider_info} ->
        case build_client(provider_info) do
          {:ok, client} -> client
          {:error, error} -> raise RuntimeError, error.message
        end

      {:error, _reason} ->
        raise_missing_config!(provider_name)
    end
  end

  @doc """
  Returns `{:ok, client}` for the active provider, or `{:error, message}` if
  unconfigured.
  """
  def client_safe do
    provider_name = Beamcore.Config.active_provider()

    case validate_selection(provider_name) do
      {:ok, provider_info} ->
        case build_client(provider_info) do
          {:ok, client} -> {:ok, client}
          {:error, error} -> {:error, error.message}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp raise_missing_config!(provider_name) do
    raise RuntimeError, missing_config_message(provider_name)
  end

  defp build_client(provider_info) do
    config = provider_client_config(provider_info)

    with :ok <- OpenAICompatible.validate_config(config),
         {:ok, %{headers: headers, token: token}} <- Auth.material(config) do
      token = token || "unused"

      {:ok,
       OpenaiEx.new(token)
       |> Map.put(:_http_headers, headers)
       |> OpenaiEx.with_base_url(provider_info.base_url)
       |> OpenaiEx.with_receive_timeout(receive_timeout(provider_info))}
    end
  end

  defp provider_client_config(provider_info) do
    default =
      provider_info.default_config
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    default
    |> Map.merge(provider_info.config || %{})
    |> Map.merge(%{
      "base_url" => provider_info.base_url,
      "default_model" => provider_info.default_model,
      "api_key" => resolve_api_key(provider_info),
      "name" => provider_info.name,
      auth: provider_info.auth,
      provider_id: provider_info.id
    })
    |> decrypt_auth_secrets()
  end

  defp receive_timeout(%{capabilities: %{local: true}}) do
    Beamcore.Config.get_setting(:local_provider_receive_timeout_ms, 120_000)
  end

  defp receive_timeout(_provider_info),
    do: Application.get_env(:beamcore, :provider_receive_timeout_ms, 30_000)

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

      %{discovery: discovery} = provider when is_atom(discovery) and not is_nil(discovery) ->
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

  def capabilities("openai", _model) do
    %Capabilities{
      chat: true,
      streaming: true,
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
      streaming: true,
      tool_calls: true,
      structured_output: true,
      latency_class: :unknown,
      retry_after: true
    }
  end

  defp custom_default(_name, config) when is_map(config) do
    has_token_url = is_binary(Map.get(config, "token_url") || Map.get(config, :token_url))

    auth =
      Map.get(config, "auth") || Map.get(config, :auth) ||
        if(has_token_url, do: :oauth2_client_credentials, else: :bearer)

    strategy = Auth.strategy(Map.put(config, "auth", auth))

    %{
      id: :openai_compatible,
      adapter: OpenAICompatible,
      base_url: nil,
      auth: auth,
      default_model: nil,
      requires_api_key?: strategy in [:bearer, :api_key],
      local?: false
    }
  end

  defp custom_default(_name, _config) do
    %{
      id: :openai_compatible,
      adapter: OpenAICompatible,
      base_url: nil,
      auth: :bearer,
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
    Map.merge(config, %{
      "base_url" => Map.get(config, "base_url") || Map.get(default, :base_url),
      "default_model" => Map.get(config, "default_model") || Map.get(default, :default_model),
      "auth" => Map.get(config, "auth") || Map.get(default, :auth),
      "api_key" => Map.get(config, "api_key")
    })
  end

  defp configured?(_name, _config, %{requires_api_key?: false}), do: true

  defp configured?(_name, config, default) do
    is_map(config) and auth_configured?(merge_config(default, config))
  end

  defp auth_configured?(config) do
    case Auth.validate_config(decrypt_auth_secrets(config)) do
      :ok -> true
      {:error, _error} -> false
    end
  end

  defp decrypt_auth_secrets(config) do
    config
    |> decrypt_secret_fields(["api_key", "client_secret", "bearer_token", "access_token"])
    |> Map.update("auth", nil, fn
      auth when is_map(auth) ->
        decrypt_secret_fields(auth, [
          "client_secret",
          "token",
          "basic_credential",
          "authorization_key"
        ])

      auth ->
        auth
    end)
  end

  defp decrypt_secret_fields(config, fields) do
    Enum.reduce(fields, config, fn key, acc ->
      case Map.get(acc, key) do
        value when is_binary(value) -> Map.put(acc, key, Beamcore.Config.decrypted_api_key(value))
        _ -> acc
      end
    end)
  end
end
