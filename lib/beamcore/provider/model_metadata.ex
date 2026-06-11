defmodule Beamcore.Provider.ModelMetadata do
  @moduledoc """
  Provider-neutral model context metadata.

  Context numbers are always annotated with their source and accuracy. Provider
  APIs are preferred when they expose reliable metadata; registry/config values
  are explicit fallbacks rather than silently treated as exact.
  """

  alias Beamcore.Provider.Registry

  defstruct provider_id: nil,
            model: nil,
            context_window: nil,
            max_output_tokens: nil,
            tokenizer: :unknown,
            supports_usage: false,
            supports_model_metadata: false,
            source: :unknown,
            accuracy: :unknown,
            fetched_at: nil,
            raw: %{}

  @type source :: :provider_api | :registry | :config | :fallback | :unknown
  @type accuracy :: :exact | :reported | :estimated | :unknown

  @type t :: %__MODULE__{
          provider_id: binary() | atom() | nil,
          model: binary() | nil,
          context_window: pos_integer() | nil,
          max_output_tokens: pos_integer() | nil,
          tokenizer: atom() | binary(),
          supports_usage: boolean(),
          supports_model_metadata: boolean(),
          source: source(),
          accuracy: accuracy(),
          fetched_at: binary() | nil,
          raw: map()
        }

  @doc """
  Resolve model metadata for a provider/model.

  The supervised health cache may return provider API metadata. If that is not
  available, this falls back to registry/config capabilities with explicit
  source and accuracy.
  """
  def resolve(provider, model, opts \\ []) when is_binary(provider) do
    health = Keyword.get(opts, :health, Beamcore.Provider.Health)

    case health_metadata(health, provider, model, opts) do
      {:ok, %__MODULE__{} = metadata} ->
        metadata

      _ ->
        fallback(provider, model)
    end
  end

  def fallback(provider, model) when is_binary(provider) do
    case Registry.get(provider) do
      nil ->
        unknown(provider, model)

      provider_info ->
        config = provider_info.config || %{}
        caps = provider_info.capabilities
        configured_context = positive_int(config, "context_window")
        configured_output = positive_int(config, "max_output_tokens")
        configured_tokenizer = Map.get(config, "tokenizer")

        source =
          cond do
            configured_context || configured_output || configured_tokenizer -> :config
            caps.context_window -> :registry
            true -> :unknown
          end

        accuracy =
          cond do
            configured_context || configured_output || configured_tokenizer -> :reported
            caps.context_window -> :estimated
            true -> :unknown
          end

        %__MODULE__{
          provider_id: provider_info.id,
          model: model || provider_info.default_model,
          context_window: configured_context || caps.context_window,
          max_output_tokens: configured_output,
          tokenizer: configured_tokenizer || tokenizer_for(provider_info),
          supports_usage: caps.token_accounting,
          supports_model_metadata: provider_info.discovery != nil,
          source: source,
          accuracy: accuracy,
          fetched_at: timestamp(),
          raw: %{}
        }
    end
  end

  def unknown(provider, model) do
    %__MODULE__{
      provider_id: provider,
      model: model,
      source: :unknown,
      accuracy: :unknown,
      fetched_at: timestamp(),
      raw: %{}
    }
  end

  def to_safe_map(%__MODULE__{} = metadata) do
    %{
      provider_id: metadata.provider_id,
      model: metadata.model,
      context_window: metadata.context_window,
      max_output_tokens: metadata.max_output_tokens,
      tokenizer: metadata.tokenizer,
      supports_usage: metadata.supports_usage,
      supports_model_metadata: metadata.supports_model_metadata,
      source: metadata.source,
      accuracy: metadata.accuracy,
      fetched_at: metadata.fetched_at
    }
  end

  def from_provider_api(provider_info, model, attrs) when is_map(attrs) do
    caps = provider_info.capabilities

    %__MODULE__{
      provider_id: provider_info.id,
      model: model || provider_info.default_model,
      context_window: positive_int(attrs, "context_window"),
      max_output_tokens: positive_int(attrs, "max_output_tokens"),
      tokenizer:
        Map.get(attrs, "tokenizer") || Map.get(attrs, :tokenizer) || tokenizer_for(provider_info),
      supports_usage: caps.token_accounting,
      supports_model_metadata: true,
      source: :provider_api,
      accuracy: provider_accuracy(attrs),
      fetched_at: timestamp(),
      raw: sanitize_raw(Map.get(attrs, "raw") || Map.get(attrs, :raw) || %{})
    }
  end

  def positive_int(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, String.to_atom(key))

    cond do
      is_integer(value) and value > 0 ->
        value

      is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} when integer > 0 -> integer
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp health_metadata(nil, _provider, _model, _opts), do: :error

  defp health_metadata(health, provider, model, opts) do
    if function_exported?(health, :model_metadata, 3) do
      health.model_metadata(provider, model, opts)
    else
      :error
    end
  catch
    _, _ -> :error
  end

  defp tokenizer_for(%{capabilities: %{token_accounting: true}}), do: :provider_reported
  defp tokenizer_for(_provider_info), do: :chars_per_token_estimate

  defp provider_accuracy(attrs) do
    case positive_int(attrs, "context_window") || positive_int(attrs, "max_output_tokens") do
      nil -> :unknown
      _ -> :reported
    end
  end

  defp sanitize_raw(raw) when is_map(raw) do
    raw
    |> Map.drop(["api_key", :api_key, "authorization", :authorization, "token", :token])
    |> Map.take(["model_info", "parameters", "details", :model_info, :parameters, :details])
  end

  defp sanitize_raw(_raw), do: %{}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
