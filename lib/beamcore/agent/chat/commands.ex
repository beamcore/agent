defmodule Beamcore.Agent.Chat.Commands do
  @moduledoc """
  Handles command parsing and execution.
  """

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Policy.ProjectPolicy

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
      "yolo" -> handle_yolo(session, output)
      "yolo on" -> enable_yolo(session, output)
      "yolo off" -> disable_yolo(session, output)
      "env" -> handle_env(session, output)
      "login" -> handle_login_prompt(session, output)
      "login " <> token -> handle_login_token(token, session, output)
      "logout" -> handle_logout(session, output)
      "api select" -> {:provider_select, session}
      "providers" -> {:provider_select, session}
      "api" -> handle_api(["list"], session, output)
      "api " <> args -> handle_api(String.split(args, " ", trim: true), session, output)
      "helper" -> handle_helper(["status"], session, output)
      "helper " <> args -> handle_helper(String.split(args, " ", trim: true), session, output)
      "help" -> handle_help(session, output)
      "policy" -> handle_policy([], session, output)
      "policy " <> args -> handle_policy(String.split(args, " ", trim: true), session, output)
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

  defp handle_yolo(session, output) do
    if session.project_policy_bypassed? do
      disable_yolo(session, output)
    else
      enable_yolo(session, output)
    end
  end

  defp enable_yolo(session, output) do
    output.("Freedom mode enabled: project policy bypassed for this session.")

    session = Session.clear_project_policy_block_history(session)

    %{
      session
      | policy_override: Beamcore.Agent.Chat.ToolPolicy.yolo(project_policy_bypassed?: true),
        project_policy_bypassed?: true
    }
  end

  defp disable_yolo(session, output) do
    output.("Freedom mode disabled: project policy restored.")
    %{session | policy_override: nil, project_policy_bypassed?: false}
  end

  defp handle_env(session, output) do
    env_str =
      System.get_env()
      |> Enum.sort()
      |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{redact_env_value(key, value)}" end)

    output.(env_str)
    session
  end

  def store_login_token(token) when is_binary(token),
    do: Beamcore.Config.put_mistral_api_key(token)

  def login_saved_message do
    if Beamcore.OpenAI.env_api_key_present?() do
      "Beamcore login saved.\nWarning: MISTRAL_API_KEY is set in this process and will override the stored login until it is unset."
    else
      "Beamcore login saved."
    end
  end

  defp handle_login_prompt(session, output) do
    output.(
      "Paste your Mistral API key. It will be securely hashed and stored locally in ~/.beamcore/config.dets."
    )

    {:login_prompt, session}
  end

  defp handle_login_token(token, session, output) do
    case store_login_token(token) do
      :ok ->
        output.(login_saved_message())
        session

      {:error, :empty_value} ->
        output.("Login token was empty; nothing was saved.")
        session
    end
  end

  defp handle_logout(session, output) do
    :ok = Beamcore.Config.delete_mistral_api_key()
    output.("Beamcore login cleared.")
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

  defp handle_helper(["status"], session, output) do
    case Beamcore.Provider.Selection.helper(session.roles) do
      %{enabled: true, provider: provider, model: model} ->
        output.("Helper enabled: #{provider}/#{model}")

      _ ->
        output.("Helper disabled. Use /helper use <provider> <model> to enable it.")
    end

    session
  end

  defp handle_helper(["list"], session, output) do
    local_providers =
      Beamcore.Provider.Registry.list()
      |> Enum.filter(& &1.capabilities.local)

    case local_providers do
      [] ->
        output.("No local helper providers are configured.")

      providers ->
        Enum.each(providers, fn provider ->
          configured = if provider.configured?, do: "configured", else: "not configured"
          output.("  #{provider.name} · local · #{configured}")
        end)
    end

    session
  end

  defp handle_helper(["models", provider], session, output) do
    case Beamcore.Provider.Registry.get(provider) do
      nil ->
        output.("Unknown provider '#{provider}'.")

      _provider ->
        case Beamcore.Provider.Registry.models(provider) do
          [] -> output.("No models discovered for '#{provider}'.")
          models -> Enum.each(models, &output.("  #{&1.id}"))
        end
    end

    session
  end

  defp handle_helper(["off"], session, output) do
    :ok = Beamcore.Config.disable_helper()
    output.("Optional context helper disabled.")
    Session.disable_helper(session)
  end

  defp handle_helper(["use", provider, model], session, output) do
    case Beamcore.Provider.Registry.validate_selection(provider) do
      {:ok, %{capabilities: %{chat: true, local: true}}} ->
        case Beamcore.Config.put_helper_selection(provider, model) do
          :ok ->
            output.("Helper enabled with #{provider}/#{model}.")
            Session.set_helper_provider(session, provider, model)

          {:error, :empty_value} ->
            output.("Provider and model must not be empty.")
            session
        end

      {:ok, _provider} ->
        output.("Provider '#{provider}' is not an available local chat provider.")
        session

      {:error, error} ->
        output.("Cannot enable helper: #{error.message}")
        session
    end
  end

  defp handle_helper(_args, session, output) do
    output.(
      "Usage: /helper status | /helper list | /helper models <provider> | /helper use <provider> <model> | /helper off"
    )

    session
  end

  defp handle_help(session, output) do
    output.("""
    Available commands:
      /new  - Start a new chat session
      /context - Show compact session context
      /context clear - Clear compact session context
      /policy - Show project policy summary
      /policy show - Show normalized project policy config
      /policy init - Create .beamcore/policy.json from the example
      /policy deny path <pattern> - Add a denied path pattern
      /policy allow-write <pattern> - Add an allowed write path pattern
      /policy read-only <pattern> - Add a read-only path pattern
      /policy tool <tool> allow|deny - Set tool permission
      /policy reload - Reload and summarize project policy
      /yolo - Toggle freedom mode for this session
      /yolo on - Bypass project policy for this session
      /yolo off - Restore project policy for this session
      /stop - Pause the session to add improved direction
      /continue - Resume the paused session
      /api select - Open interactive API provider selector
      /providers - Open interactive API provider selector
      /api list - List all configured API providers
      /api use <provider> - Switch active API provider
      /api add <provider> <token> [<base_url>] [<default_model>] - Add/update provider config
      /api delete <provider> - Delete a provider config
      /helper status - Show optional helper selection
      /helper list - List providers available for helper use
      /helper models <provider> - Discover models for a local provider
      /helper use <provider> <model> - Enable an explicitly selected local helper model
      /helper off - Disable the helper completely
      /login - Configure your default API key
      /logout - Clear stored default login
      /env  - Print env variables with secrets redacted
      /help - Show this help message
    """)

    session
  end

  defp handle_context(session, output) do
    output.(
      [
        Beamcore.Agent.Chat.Context.summary(session.context),
        ProjectPolicy.summary(ProjectPolicy.load())
      ]
      |> Enum.join("\n")
    )

    session
  end

  defp handle_context_clear(session, output) do
    output.("Session context cleared.")
    {language, build_system} = session.project_nature
    %{session | context: Beamcore.Agent.Chat.Context.new(language, build_system)}
  end

  defp handle_policy(args, session, output) do
    message =
      case policy_command(args) do
        {:show_summary} ->
          ProjectPolicy.summary(ProjectPolicy.load())

        {:show_config} ->
          ProjectPolicy.load() |> ProjectPolicy.show()

        {:init} ->
          case ProjectPolicy.init() do
            {:ok, policy} -> "Project policy initialized: #{ProjectPolicy.summary(policy)}"
            {:error, reason} -> "Error: #{reason}"
          end

        {:reload} ->
          "Project policy reloaded. #{ProjectPolicy.summary(ProjectPolicy.load())}"

        {:reset, confirmed?} ->
          if confirmed? do
            reset_policy()
          else
            "Error: /policy reset weakens policy. Re-run with --confirm."
          end

        {:mutate, action, confirmed?} ->
          mutate_policy(action, confirmed?)

        {:error, reason} ->
          "Error: #{reason}"
      end

    output.(message)
    session
  end

  defp policy_command([]), do: {:show_summary}
  defp policy_command(["show"]), do: {:show_config}
  defp policy_command(["reload"]), do: {:reload}
  defp policy_command(["init"]), do: {:init}
  defp policy_command(["reset" | rest]), do: {:reset, confirm_flag?(rest)}

  defp policy_command(["deny", "path", pattern | rest]),
    do: {:mutate, {:add_deny, pattern}, confirm_flag?(rest)}

  defp policy_command(["allow-write", pattern | rest]),
    do: {:mutate, {:add_allow_write, pattern}, confirm_flag?(rest)}

  defp policy_command(["read-only", pattern | rest]),
    do: {:mutate, {:add_read_only, pattern}, confirm_flag?(rest)}

  defp policy_command(["tool", tool, permission | rest]),
    do: {:mutate, {:set_tool, tool, permission}, confirm_flag?(rest)}

  defp policy_command(["remove", "deny", "path", pattern | rest]),
    do: {:mutate, {:remove_deny, pattern}, confirm_flag?(rest)}

  defp policy_command(["remove", "allow-write", pattern | rest]),
    do: {:mutate, {:remove_allow_write, pattern}, confirm_flag?(rest)}

  defp policy_command(["remove", "read-only", pattern | rest]),
    do: {:mutate, {:remove_read_only, pattern}, confirm_flag?(rest)}

  defp policy_command(["remove", "tool", tool | rest]),
    do: {:mutate, {:remove_tool, tool}, confirm_flag?(rest)}

  defp policy_command(_args) do
    {:error,
     "Malformed /policy command. Try /policy, /policy show, /policy init, /policy deny path <pattern>, or /policy tool <tool> allow|deny."}
  end

  defp mutate_policy(action, confirmed?) do
    old_policy = editable_policy()

    case apply_policy_action(old_policy, action) do
      {:ok, new_policy, label} ->
        if ProjectPolicy.weakening_change?(old_policy, new_policy) and not confirmed? do
          "Error: #{label} weakens project policy. Re-run with --confirm."
        else
          case ProjectPolicy.save(new_policy) do
            {:ok, saved} -> "Project policy updated: #{label}. #{ProjectPolicy.summary(saved)}"
            {:error, reason} -> "Error: cannot save project policy: #{inspect(reason)}"
          end
        end

      {:error, reason} ->
        "Error: #{reason}"
    end
  end

  defp reset_policy do
    path =
      Path.join(Beamcore.Agent.PathSafety.workspace_root(), ProjectPolicy.config_path())

    case File.rm(path) do
      :ok -> "Project policy reset. #{ProjectPolicy.summary(ProjectPolicy.load())}"
      {:error, :enoent} -> "Project policy reset. #{ProjectPolicy.summary(ProjectPolicy.load())}"
      {:error, reason} -> "Error: cannot reset project policy: #{reason}"
    end
  end

  defp editable_policy do
    case ProjectPolicy.load() do
      %{loaded?: true, valid?: true} = policy -> policy
      %{loaded?: false} -> ProjectPolicy.default()
      %{valid?: false, error: error} -> raise "Project policy is invalid: #{error}"
    end
  rescue
    error -> ProjectPolicy.default() |> Map.put(:error, Exception.message(error))
  end

  defp apply_policy_action(%{error: error}, _action) when is_binary(error),
    do: {:error, error}

  defp apply_policy_action(policy, {:add_deny, pattern}),
    do: {:ok, ProjectPolicy.add_deny_path(policy, pattern), "policy deny #{pattern}"}

  defp apply_policy_action(policy, {:add_allow_write, pattern}),
    do:
      {:ok, ProjectPolicy.add_allow_write_path(policy, pattern), "policy allow-write #{pattern}"}

  defp apply_policy_action(policy, {:add_read_only, pattern}),
    do: {:ok, ProjectPolicy.add_read_only_path(policy, pattern), "policy read-only #{pattern}"}

  defp apply_policy_action(policy, {:remove_deny, pattern}),
    do: {:ok, ProjectPolicy.remove_deny_path(policy, pattern), "policy remove deny #{pattern}"}

  defp apply_policy_action(policy, {:remove_allow_write, pattern}),
    do:
      {:ok, ProjectPolicy.remove_allow_write_path(policy, pattern),
       "policy remove allow-write #{pattern}"}

  defp apply_policy_action(policy, {:remove_read_only, pattern}),
    do:
      {:ok, ProjectPolicy.remove_read_only_path(policy, pattern),
       "policy remove read-only #{pattern}"}

  defp apply_policy_action(policy, {:set_tool, tool, permission}) do
    cond do
      tool not in ProjectPolicy.known_tools() ->
        {:error, "Unknown tool #{inspect(tool)}."}

      permission not in ProjectPolicy.permissions() ->
        {:error, "Unknown permission #{inspect(permission)}. Use allow or deny."}

      true ->
        {:ok, ProjectPolicy.set_tool_permission(policy, tool, permission),
         "policy tool #{tool} #{permission}"}
    end
  end

  defp apply_policy_action(policy, {:remove_tool, tool}) do
    if tool in ProjectPolicy.known_tools() do
      {:ok, ProjectPolicy.remove_tool_permission(policy, tool), "policy remove tool #{tool}"}
    else
      {:error, "Unknown tool #{inspect(tool)}."}
    end
  end

  defp confirm_flag?(args), do: "--confirm" in args

  defp handle_unknown(command, session, _output, false) do
    Beamcore.Agent.Core.Pretty.print_error("Unknown command: /#{command}")
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
        "MISTRAL_API_KEY",
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
