defmodule Beamcore.Gateway.Commands do
  @moduledoc """
  Shared command handling and text messages for all platform adapters.
  """

  alias Beamcore.Config
  alias Beamcore.Gateway.SessionStore
  alias Beamcore.Provider.Registry

  @type send_fn :: (binary(), binary() -> :ok)

  @doc """
  Route a text message to the appropriate handler.

  Returns `{:command, response_text}` or `{:message, text}` for agent dispatch.
  """
  @spec route(binary(), binary()) ::
          {:command, binary()} | {:message, binary()} | {:api, list(binary())}
  def route("/myid" <> _, _chat_key), do: {:command, nil}
  def route("/start", _chat_key), do: {:command, welcome_text()}
  def route("/new", chat_key), do: reset(chat_key)
  def route("/reset", chat_key), do: reset(chat_key)
  def route("/status", chat_key), do: {:command, status_text(chat_key)}
  def route("/stop", _chat_key), do: {:command, :cancel}
  def route("/help", _chat_key), do: {:command, help_text()}
  def route("/api", _chat_key), do: {:command, api_help_text()}
  def route("/api list", _chat_key), do: {:command, providers_text()}
  def route("/api " <> args, _chat_key), do: {:api, String.split(args, " ", trim: true)}
  def route("/" <> _, _chat_key), do: {:command, "Unknown command. /help"}
  def route(text, _chat_key), do: {:message, text}

  defp reset(chat_key) do
    SessionStore.reset(chat_key)
    {:command, "Session cleared."}
  end

  @doc """
  Execute an /api subcommand. Returns response text.
  """
  def exec_api(["add", name, key]), do: add_provider(name, key, nil, nil)
  def exec_api(["add", name, key, url]), do: add_provider(name, key, url, nil)
  def exec_api(["add", name, key, url, model]), do: add_provider(name, key, url, model)

  def exec_api(["set", name]) do
    case Registry.get(name) do
      nil ->
        "Unknown provider: #{name}"

      _ ->
        Config.set_active_provider(name)
        "Active provider: #{name}"
    end
  end

  def exec_api(_), do: api_help_text()

  defp add_provider(name, key, base_url, model) do
    config =
      %{"api_key" => key}
      |> maybe_put("base_url", base_url)
      |> maybe_put("default_model", model)

    case Config.put_provider(name, config) do
      :ok ->
        Config.set_active_provider(name)
        "Provider '#{name}' configured and activated!"

      {:error, reason} ->
        "Failed: #{inspect(reason)}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  # -- Text messages -----------------------------------------------------------

  def welcome_text do
    """
    BeamCore Agent

    Send me a message to get started.
    /new - Clear session
    /api - Configure LLM provider
    /status - Session info
    /stop - Cancel task
    /help - Help
    """
  end

  def help_text do
    """
    /new     - Clear session
    /api     - Configure provider
    /status  - Provider, model, status
    /stop    - Cancel running task
    /help    - This message
    """
  end

  def status_text(chat_key) do
    provider = Config.active_provider() || "not set"
    model = Config.active_model(:chat) || "default"
    busy = SessionStore.busy?(chat_key)
    "Provider: #{provider}\nModel: #{model}\nStatus: #{if busy, do: "processing", else: "idle"}"
  end

  def providers_text do
    lines =
      Enum.map(Registry.list(), fn p ->
        status = if p.configured?, do: "ok", else: "no key"
        active = if p.active?, do: " [ACTIVE]", else: ""
        "  #{p.name} - #{status}#{active}"
      end)

    "Providers:\n#{Enum.join(lines, "\n")}"
  end

  def api_help_text do
    """
    /api add <name> <key> [base_url] [model]
    Examples:
    /api add deepseek sk-xxx
    /api add groq gsk_xxx https://api.groq.com/openai/v1 llama-3.3-70b-versatile

    /api list - Show providers
    /api set <name> - Switch provider
    """
  end
end
