defmodule Beamcore.Provider.Adapters.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible chat completions adapter.

  Provider brands configure this adapter through `Beamcore.Provider.Registry`;
  this module owns only the wire protocol.
  """

  @behaviour Beamcore.Provider

  alias Beamcore.Provider.Error

  @completions_module Application.compile_env(
                        :agent,
                        :completions_module,
                        OpenaiEx.Chat.Completions
                      )

  @impl true
  def id, do: :openai_compatible

  @impl true
  def list_models(config) do
    model = Map.get(config, "default_model") || Map.get(config, :default_model)
    capabilities = Map.get(config, :capabilities) || Map.get(config, "capabilities")

    if is_binary(model) do
      {:ok,
       [
         %Beamcore.Provider.Model{
           id: model,
           name: model,
           capabilities: capabilities || %Beamcore.Provider.Capabilities{}
         }
       ]}
    else
      {:ok, []}
    end
  end

  @impl true
  def capabilities(_model, config) do
    Map.get(config, :capabilities) ||
      Map.get(config, "capabilities") ||
      %Beamcore.Provider.Capabilities{}
  end

  @impl true
  def chat(request, config) do
    with {:ok, client} <- client(config),
         {:ok, params} <- params(request) do
      @completions_module.create(client, params)
      |> normalize()
    end
  end

  @impl true
  def stream(_request, _receiver, config) do
    {:error, Error.exception(provider: provider_id(config), kind: :unsupported_capability)}
  end

  @impl true
  def validate_config(config) do
    auth = Map.get(config, :auth) || Map.get(config, "auth") || :bearer
    token = Map.get(config, "api_key") || Map.get(config, :api_key)

    cond do
      auth in [:none, "none"] ->
        :ok

      not is_binary(token) ->
        {:error,
         Error.exception(
           provider: provider_id(config),
           kind: :missing_config,
           message: "Provider #{provider_name(config)} requires an API key."
         )}

      true ->
        :ok
    end
  end

  defp client(config) do
    token = Map.get(config, "api_key") || Map.get(config, :api_key) || token_for_auth(config)
    base_url = Map.get(config, "base_url") || Map.get(config, :base_url)

    if is_binary(token) and is_binary(base_url) do
      {:ok,
       OpenaiEx.new(token)
       |> OpenaiEx.with_base_url(base_url)
       |> OpenaiEx.with_receive_timeout(Map.get(config, :receive_timeout, 30_000))}
    else
      {:error,
       Error.exception(
         provider: provider_id(config),
         kind: :missing_config,
         message: "Provider #{provider_name(config)} is missing API configuration."
       )}
    end
  end

  defp token_for_auth(config) do
    case Map.get(config, :auth) || Map.get(config, "auth") do
      :none -> "unused"
      "none" -> "unused"
      _ -> nil
    end
  end

  defp params(%{model: model, messages: messages, tools: tools} = request) do
    base = %{model: model, messages: messages, tools: tools || []}
    extras = Map.take(request, [:temperature, :top_p, :max_tokens])
    {:ok, Map.merge(base, extras)}
  end

  defp params(_request) do
    {:error,
     Error.exception(
       kind: :bad_request,
       message: "Provider request must include model, messages, and tools."
     )}
  end

  defp normalize({:ok, response}), do: {:ok, response}
  defp normalize({:error, %OpenaiEx.Error{} = error}), do: {:error, error}
  defp normalize({:error, error}), do: {:error, error}

  defp provider_id(config), do: Map.get(config, :provider_id) || Map.get(config, "provider_id")

  defp provider_name(config),
    do: Map.get(config, :name) || Map.get(config, "name") || "configured provider"
end
