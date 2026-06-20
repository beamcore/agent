defmodule Beamcore.Provider.Router do
  @moduledoc """
  Runtime entry point for provider/model chat calls.
  """

  alias Beamcore.Provider.{Error, Registry, Scheduler}

  def chat(selection, request, opts \\ [])

  def chat(%{provider: provider, model: model}, request, opts) do
    with {:ok, provider_info} <- Registry.validate_selection(provider),
         {:ok, adapter} <- adapter(provider_info),
         :ok <- ensure_chat_capability(provider_info, model),
         config <- provider_config(provider_info),
         :ok <- adapter.validate_config(config) do
      key = scheduler_key(provider_info, model, config)

      Scheduler.wait(key,
        interval: scheduler_interval(provider_info),
        name: Keyword.get(opts, :scheduler, Scheduler),
        wait_fun: Keyword.get(opts, :wait_fun)
      )

      request = Map.put(request, :model, model)

      case adapter.chat(request, config) do
        {:error, %OpenaiEx.Error{kind: :rate_limit} = error} = result ->
          apply_cooldown(key, error, opts)
          result

        {:error, %Error{kind: :rate_limit} = error} = result ->
          apply_cooldown(key, error, opts)
          result

        result ->
          result
      end
    end
  end

  def chat(_selection, _request, _opts) do
    {:error,
     Error.exception(
       kind: :invalid_config,
       message: "Provider selection must include provider and model."
     )}
  end

  defp adapter(%{adapter: module}) when is_atom(module) and not is_nil(module), do: {:ok, module}

  defp adapter(provider_info) do
    {:error,
     Error.exception(
       provider: Map.get(provider_info, :id),
       kind: :invalid_config,
       message: "Provider #{Map.get(provider_info, :name)} is missing an adapter."
     )}
  end

  defp ensure_chat_capability(provider_info, _model) do
    if provider_info.capabilities.chat do
      :ok
    else
      {:error,
       Error.exception(
         provider: provider_info.id,
         kind: :unsupported_capability,
         message: "Provider #{provider_info.name} does not support chat."
       )}
    end
  end

  defp provider_config(provider_info) do
    %{
      "base_url" => provider_info.base_url,
      "default_model" => provider_info.default_model,
      "api_key" => Registry.resolve_api_key(provider_info),
      "name" => provider_info.name,
      receive_timeout: receive_timeout(provider_info),
      provider_id: provider_info.id,
      auth: provider_info.auth,
      capabilities: provider_info.capabilities
    }
  end

  defp receive_timeout(%{capabilities: %{local: true}}) do
    Beamcore.Config.get_setting(:local_provider_receive_timeout_ms, 120_000)
  end

  defp receive_timeout(_provider_info),
    do: Application.get_env(:beamcore, :provider_receive_timeout_ms, 30_000)

  defp scheduler_key(provider_info, model, config) do
    account = account_fingerprint(Map.get(config, "api_key"))
    {provider_info.id, account, model}
  end

  defp account_fingerprint(nil), do: nil

  defp account_fingerprint(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp scheduler_interval(%{capabilities: %{local: true}}), do: 0

  defp scheduler_interval(_provider_info),
    do: Application.get_env(:beamcore, :rate_limit_ms, 1000)

  defp apply_cooldown(key, %OpenaiEx.Error{kind: :rate_limit}, opts) do
    cooldown_key(15_000, key, opts)
  end

  defp apply_cooldown(_key, %OpenaiEx.Error{}, _opts), do: :ok

  defp apply_cooldown(key, %Error{retry_after_ms: retry_after_ms}, opts) do
    cooldown_key(retry_after_ms, key, opts)
  end

  defp cooldown_key(ms, key, opts) when is_integer(ms) and ms > 0 do
    Scheduler.cooldown(key, ms, name: Keyword.get(opts, :scheduler, Scheduler))
  end

  defp cooldown_key(_ms, _key, _opts), do: :ok
end
