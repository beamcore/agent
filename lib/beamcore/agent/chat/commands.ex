defmodule Beamcore.Agent.Chat.Commands do
  @moduledoc """
  Handles command parsing and execution.
  """

  alias Beamcore.Agent.Chat.Session

  def provider_defaults do
    Beamcore.Provider.Registry.defaults()
    |> Map.new(fn {name, config} ->
      {name, %{base_url: config.base_url, default_model: config.default_model}}
    end)
  end

  @doc """
  Handle a command and return the updated session.
  """
  def execute(command, session, opts \\ []) do
    output = Keyword.get(opts, :output, &IO.puts/1)
    custom_output? = Keyword.has_key?(opts, :output)

    case command do
      "new" -> handle_new(session, nil, output)
      "new " <> arg -> handle_new(session, String.trim(arg), output)
      "context" -> handle_context(session, output)
      "context clear" -> handle_context_clear(session, output)
      "env" -> handle_env(session, output)
      "yolo" -> handle_yolo(session, output)
      "api" -> handle_api(["list"], session, output)
      "api " <> args -> handle_api(String.split(args, " ", trim: true), session, output)
      "help" -> handle_help(session, output)
      _ -> handle_unknown(command, session, output, custom_output?)
    end
  end

  defp handle_new(session, session_id, output) do
    if session_id do
      output.("Resuming session '#{session_id}'...")
    else
      output.("Starting new session...")
    end

    opts = [
      workspace_root: session.workspace_root,
      screen_type: session.screen_type,
      roles: session.roles
    ]

    if session_id do
      case Session.resume(session_id, session.client, opts) do
        {:ok, resumed} ->
          resumed

        {:error, _reason} ->
          opts = Keyword.put(opts, :session_id, session_id)
          Session.new(session.client, opts)
      end
    else
      Session.new(session.client, opts)
    end
  end

  defp handle_env(session, output) do
    env_str =
      System.get_env()
      |> Enum.sort()
      |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{redact_env_value(key, value)}" end)

    output.(env_str)
    session
  end

  defp handle_yolo(session, output) do
    output.("Beamcore is already running in autonomous yolo mode.")
    session
  end

  defp handle_api(args, session, output) do
    case args do
      ["list"] ->
        providers = Beamcore.Config.list_providers()

        active =
          case session.roles do
            %{primary: %{provider: provider}} -> provider
            _ -> Beamcore.Config.active_provider()
          end

        output.("Configured API Providers (* denotes active in this session):")

        if map_size(providers) == 0 do
          output.("  No custom providers configured yet. Active default: #{active}")
        else
          for {name, config} <- Enum.sort(providers) do
            prefix = if name == active, do: "  * ", else: "    "
            base_url = Map.get(config, "base_url")
            model = Map.get(config, "default_model") || "default"
            output.("#{prefix}#{name} (#{base_url}) - model: #{model}")
          end
        end

        session

      ["use", provider] ->
        providers = Beamcore.Config.list_providers()
        Beamcore.Config.set_active_provider(session.screen_type, provider)

        unless Map.has_key?(providers, provider) do
          output.(
            "Warning: Provider '#{provider}' is not configured yet. Run '/api add #{provider} <token>' to configure."
          )
        end

        new_session = Session.set_primary_provider(session, provider)
        new_model = new_session.roles.primary.model
        Beamcore.Config.set_active_model(session.screen_type, new_model)

        output.("Switched active provider to '#{provider}'.")
        new_session

      ["add", provider, token] ->
        defaults = Map.get(provider_defaults(), provider, %{})
        base_url = Map.get(defaults, :base_url)
        default_model = Map.get(defaults, :default_model)

        if base_url do
          Beamcore.Config.put_provider(provider, %{
            api_key: token,
            base_url: base_url,
            default_model: default_model
          })

          output.("Provider '#{provider}' configured successfully with defaults.")
          Beamcore.Config.set_active_provider(session.screen_type, provider)
          Beamcore.Config.set_active_model(session.screen_type, default_model)
          Session.set_primary_provider(session, provider, default_model)
        else
          output.("Error: Unknown provider '#{provider}'. Please specify base URL and model:")
          output.("Usage: /api add <provider> <token> <base_url> [<default_model>]")
          session
        end

      ["add", provider, token, base_url] ->
        defaults = Map.get(provider_defaults(), provider, %{})
        default_model = Map.get(defaults, :default_model) || "default"

        Beamcore.Config.put_provider(provider, %{
          api_key: token,
          base_url: base_url,
          default_model: default_model
        })

        output.("Provider '#{provider}' configured successfully.")
        Beamcore.Config.set_active_provider(session.screen_type, provider)
        Beamcore.Config.set_active_model(session.screen_type, default_model)
        Session.set_primary_provider(session, provider, default_model)

      ["add", provider, token, base_url, default_model] ->
        Beamcore.Config.put_provider(provider, %{
          api_key: token,
          base_url: base_url,
          default_model: default_model
        })

        output.("Provider '#{provider}' configured successfully.")
        Beamcore.Config.set_active_provider(session.screen_type, provider)
        Beamcore.Config.set_active_model(session.screen_type, default_model)
        Session.set_primary_provider(session, provider, default_model)

      ["delete", provider] ->
        providers = Beamcore.Config.list_providers()

        if Map.has_key?(providers, provider) do
          configs = Map.delete(providers, provider)
          Beamcore.Config.put(:api_configs, Jason.encode!(configs))
          output.("Provider '#{provider}' deleted.")

          session_provider =
            case session.roles do
              %{primary: %{provider: p}} -> p
              _ -> nil
            end

          active_provider_before = Beamcore.Config.active_provider()

          session =
            if session_provider == provider do
              default_provider = Beamcore.Provider.Registry.default_primary_provider_name()
              output.("Reset session provider to '#{default_provider}'.")
              Beamcore.Config.set_active_provider(session.screen_type, default_provider)
              default_model = Beamcore.Agent.Chat.API.default_model()
              Beamcore.Config.set_active_model(session.screen_type, default_model)
              Session.set_primary_provider(session, default_provider)
            else
              session
            end

          if active_provider_before == provider do
            default_provider = Beamcore.Provider.Registry.default_primary_provider_name()
            Beamcore.Config.set_active_provider(default_provider)
            output.("Reset active provider to '#{default_provider}'.")
          end

          session
        else
          output.("Provider '#{provider}' not found.")
          session
        end

      _ ->
        output.("Invalid /api command. Usage:")
        output.("  /api list")
        output.("  /api use <provider>")
        output.("  /api add <provider> <token> [<base_url>] [<default_model>]")
        output.("  /api delete <provider>")
        session
    end
  end

  defp handle_help(session, output) do
    output.("""
    Available commands:
      /new  - Start a new chat session
      /context - Show compact session context
      /context clear - Clear compact session context
      /stop - Pause the session to add improved direction
      /api list - List all configured API providers
      /api use <provider> - Switch active API provider
      /api add <provider> <token> [<base_url>] [<default_model>] - Add/update provider config
      /api delete <provider> - Delete a provider config
      /yolo - Reaffirm the default autonomous mode
      /env  - Print env variables with secrets redacted
      /help - Show this help message
    """)

    session
  end

  defp handle_context(session, output) do
    output.(Beamcore.Agent.Chat.Context.summary(session.context))

    session
  end

  defp handle_context_clear(session, output) do
    output.("Session context cleared.")
    %{session | context: Beamcore.Agent.Chat.Context.new()}
  end

  defp handle_unknown(command, session, _output, false) do
    IO.puts("Unknown command: /#{command}")
    session
  end

  defp handle_unknown(command, session, output, true) do
    output.("Error: Unknown command: /#{command}")
    session
  end

  defp redact_env_value(key, value) do
    if secret_env_key?(key), do: "[REDACTED]", else: value
  end

  defp secret_env_key?(key) do
    key = String.upcase(key)

    Enum.any?(
      [
        "OPENAI_API_KEY",
        "API_KEY",
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "COOKIE",
        "KEY"
      ],
      &String.contains?(key, &1)
    )
  end
end
