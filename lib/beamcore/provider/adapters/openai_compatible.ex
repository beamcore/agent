defmodule Beamcore.Provider.Adapters.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible chat completions adapter.

  Provider brands configure this adapter through `Beamcore.Provider.Registry`;
  this module owns only the wire protocol.
  """

  @behaviour Beamcore.Provider

  alias Beamcore.Provider.{Auth, Error}

  @completions_module Application.compile_env(
                        :beamcore,
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
    with {:ok, params} <- params(request) do
      params = maybe_order_system_messages_first(params, config)

      if Auth.request_options(config) == [] and not Auth.tls_auto?(config) do
        with {:ok, client} <- client(config) do
          @completions_module.create(client, params)
          |> normalize()
        end
      else
        compatible_request(params, config)
      end
    end
  end

  @impl true
  def stream(request, receiver, config) when is_pid(receiver) do
    with {:ok, params} <- params(request),
         {:ok, client} <- client(config) do
      params = Map.put(params, :stream, true)
      params = Map.put(params, :stream_options, %{include_usage: true})

      spawn(fn ->
        File.write!("/tmp/beamcore_stream.log", "spawned consumer process\n", [:append])
        case @completions_module.create(client, params, stream: true) do
          {:ok, %{body_stream: body_stream, task_pid: task_pid}} ->
            File.write!("/tmp/beamcore_stream.log", "create ok, consuming stream\n", [:append])
            try do
              body_stream
              |> Stream.flat_map(fn
                events when is_list(events) -> events
                other -> [other]
              end)
              |> Enum.each(fn
                %{data: chunk} when is_map(chunk) ->
                  send(receiver, {:stream_chunk, chunk})
                _other ->
                  :ok
              end)

              send(receiver, {:stream_done, task_pid})
            rescue
              e -> send(receiver, {:stream_error, e, task_pid})
            catch
              kind, reason ->
                send(receiver, {:stream_error, {kind, reason}, task_pid})
            end

          {:error, reason} ->
            File.write!("/tmp/beamcore_stream.log", "create FAILED: " <> inspect(reason) <> "\n", [:append])
            send(receiver, {:stream_error, reason, nil})
        end
      end)

      {:ok, make_ref()}
    else
      error ->
        File.write!("/tmp/beamcore_stream.log", "stream with-clause error: " <> inspect(error) <> "\n", [:append])
        error
    end
  end

  @impl true
  def validate_config(config) do
    cond do
      not is_binary(base_url(config)) ->
        {:error,
         Error.exception(
           provider: provider_id(config),
           kind: :missing_config,
           message: "Provider #{provider_name(config)} is missing base_url."
         )}

      true ->
        Auth.validate_config(config)
    end
  end

  defp client(config) do
    with {:ok, %{headers: headers, token: token}} <- Auth.material(config) do
      token = token || "unused"

      {:ok,
       OpenaiEx.new(token)
       |> Map.put(:_http_headers, headers)
       |> OpenaiEx.with_base_url(base_url(config))
       |> OpenaiEx.with_receive_timeout(Map.get(config, :receive_timeout, 30_000))}
    end
  end

  def params(%{model: model, messages: messages, tools: tools} = request) do
    base = %{model: model, messages: messages, tools: tools || []}
    extras = Map.take(request, [:temperature, :top_p, :max_tokens])
    {:ok, Map.merge(base, extras)}
  end

  def params(_request) do
    {:error,
     Error.exception(
       kind: :bad_request,
       message: "Provider request must include model, messages, and tools."
     )}
  end

  defp compatible_request(params, config) do
    with {:ok, %{headers: headers}} <- Auth.material(config) do
      http_client =
        Application.get_env(:beamcore, :compatible_http_client, Req)

      config
      |> chat_completions_url()
      |> post_compatible(http_client, params, headers, config, :configured)
      |> maybe_retry_unknown_ca(config, fn ->
        config
        |> chat_completions_url()
        |> post_compatible(http_client, params, headers, config, :insecure)
      end)
      |> normalize_compatible_response()
    end
  end

  defp post_compatible(url, http_client, params, headers, config, tls_mode) do
    http_client.post(
      url,
      [
        json: params,
        headers: [{"Content-Type", "application/json"} | headers],
        receive_timeout: Map.get(config, :receive_timeout, 30_000)
      ] ++ Auth.request_options(config, tls_mode)
    )
  end

  defp maybe_retry_unknown_ca({:error, reason}, config, retry_fun) do
    if Auth.tls_auto?(config) and Auth.unknown_ca_error?(reason),
      do: retry_fun.(),
      else: {:error, reason}
  end

  defp maybe_retry_unknown_ca(result, _config, _retry_fun), do: result

  defp normalize_compatible_response({:ok, %{status: status, body: body}})
       when status >= 200 and status < 300,
       do: {:ok, body}

  defp normalize_compatible_response({:ok, %{status: status, body: %{"error" => error}}}) do
    {:error,
     Error.exception(
       kind: :provider_error,
       message: "Provider request failed with status #{status}: #{inspect(error)}.",
       status: status
     )}
  end

  defp normalize_compatible_response({:ok, %{status: status, body: body}}) do
    {:error,
     Error.exception(
       kind: :provider_error,
       message: "Provider request failed with status #{status}: #{inspect(body)}.",
       status: status
     )}
  end

  defp normalize_compatible_response({:error, reason}) do
    {:error,
     Error.exception(
       kind: :unavailable,
       message: "Provider request failed: #{inspect(reason)}."
     )}
  end

  defp normalize({:ok, response}), do: {:ok, response}
  defp normalize({:error, %OpenaiEx.Error{} = error}), do: {:error, error}
  defp normalize({:error, error}), do: {:error, error}

  defp chat_completions_url(config) do
    config
    |> base_url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/chat/completions")
  end

  defp maybe_order_system_messages_first(params, config) do
    if oauth2?(config) do
      Map.update(params, :messages, [], &normalize_oauth2_messages/1)
    else
      params
    end
  end

  defp oauth2?(config),
    do: Beamcore.Provider.Auth.strategy(config) == :oauth2_client_credentials

  defp normalize_oauth2_messages(messages) when is_list(messages) do
    {system, rest} = Enum.split_with(messages, &(message_role(&1) == "system"))

    case system do
      [] -> rest
      [one] -> [one | rest]
      [_ | _] -> [merge_system_messages(system) | rest]
    end
  end

  defp normalize_oauth2_messages(messages), do: messages

  defp merge_system_messages(system_messages) do
    first = List.first(system_messages)

    content =
      system_messages
      |> Enum.map(&message_content/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    case first do
      %{role: _} = message -> %{message | role: "system", content: content}
      %{"role" => _} = message -> %{message | "role" => "system", "content" => content}
      _ -> %{role: "system", content: content}
    end
  end

  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => role}), do: role
  defp message_role(_message), do: nil

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(_message), do: ""

  defp base_url(config), do: Map.get(config, "base_url") || Map.get(config, :base_url)

  defp provider_id(config), do: Map.get(config, :provider_id) || Map.get(config, "provider_id")

  defp provider_name(config),
    do: Map.get(config, :name) || Map.get(config, "name") || "configured provider"
end
