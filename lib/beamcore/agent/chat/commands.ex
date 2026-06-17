defmodule Beamcore.Agent.Chat.Commands do
  @moduledoc """
  Handles command parsing and execution.
  """

  alias Beamcore.Agent.Chat.Session

  @doc """
  Handle a command and return the updated session.
  """
  def execute(command, session, opts \\ []) do
    output = Keyword.get(opts, :output, fn msg -> Beamcore.AppLog.info(msg) end)

    case command do
      "compress" -> handle_compress(session, output)
      "new" -> handle_new(session, nil, output)
      "new " <> arg -> handle_new(session, String.trim(arg), output)
      "env" -> handle_env(session, output)
      "api" -> handle_api(["list"], session, output)
      "api " <> args -> handle_api(String.split(args, " ", trim: true), session, output)
      "help" -> handle_help(session, output)
      _ -> handle_unknown(command, session, output)
    end
  end

  defp handle_new(session, session_id, output) do
    opts = [
      workspace_root: session.workspace_root,
      screen_type: session.screen_type,
      roles: session.roles
    ]

    case session_id do
      nil ->
        output.("Starting new session...")
        Session.new(session.client, opts)

      id ->
        output.("Starting new session '#{id}'...")
        Session.new(session.client, Keyword.put(opts, :session_id, id))
    end
  end

  defp handle_compress(session, output) do
    output.("Compressing session context...")
    Session.summarize_and_rollover(session, session.messages, nil)
  end

  defp handle_env(session, output) do
    providers = Beamcore.Config.list_providers()
    active = Beamcore.Config.active_provider()

    provider_str =
      providers
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, config} ->
        base_url = Map.get(config, "base_url", "n/a")
        model = Map.get(config, "default_model", "n/a")
        flag = if name == active, do: " *", else: ""
        "  #{name}#{flag}: #{base_url} (#{model})"
      end)

    settings = [
      {"active_provider", active || "(none)"},
      {"active_model", Beamcore.Agent.Chat.API.default_model() || "(none)"}
    ]

    settings_str =
      Enum.map_join(settings, "\n", fn {k, v} -> "#{k}: #{v}" end)

    output.("Settings:\n#{settings_str}\n\nProviders:\n#{provider_str}")
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
            model = Map.get(config, "default_model") || "(not set)"
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

      ["add", provider, token | rest] ->
        known = Beamcore.Provider.Registry.get(provider)
        base_url = List.first(rest) || (known && known.base_url)

        model =
          cond do
            length(rest) > 1 -> List.last(rest)
            known && known.default_model -> known.default_model
            true -> nil
          end

        cond do
          !base_url ->
            output.("Error: Unknown provider '#{provider}'. Please specify base URL:")
            output.("Usage: /api add <provider> <token> <base_url> [<default_model>]")
            session

          !model ->
            output.("Error: No default model for '#{provider}'. Please specify one:")
            output.("Usage: /api add <provider> <token> <base_url> <model>")
            session

          true ->
            Beamcore.Config.put_provider(provider, %{
              api_key: token,
              base_url: base_url,
              default_model: model
            })

            output.("Provider '#{provider}' configured successfully.")
            Beamcore.Config.set_active_provider(session.screen_type, provider)
            Beamcore.Config.set_active_model(session.screen_type, model)
            Session.set_primary_provider(session, provider, model)
        end

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
      /compress - Compress/rollover the session context
      /api list - List all configured API providers
      /api use <provider> - Switch active API provider
      /api add <provider> <token> [<base_url>] [<default_model>] - Add/update provider config
      /api delete <provider> - Delete a provider config
      /env  - Print env variables with secrets redacted
      /help - Show this help message
    """)

    session
  end

  defp handle_unknown(command, session, output) do
    output.("Error: Unknown command: /#{command}")
    session
  end
end
