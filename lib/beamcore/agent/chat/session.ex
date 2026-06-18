defmodule Beamcore.Agent.Chat.Session do
  @moduledoc """
  Manages chat sessions and persists them to disk.
  """

  alias Beamcore.Agent.Chat.Session.{Compaction, MessageCleaner}

  defstruct [
    :messages,
    :client,
    :session_id,
    :log_file,
    :total_prompt_tokens,
    :total_completion_tokens,
    :total_tokens,
    :last_prompt_tokens,
    :compaction_count,
    :workspace_root,
    :roles,
    :screen_type,
    :mode_settings
  ]

  @colors ~w(red blue green yellow purple orange pink brown black white gray cyan magenta lime maroon navy olive teal silver gold)
  @animals ~w(cat dog bird fish elephant lion tiger bear wolf fox owl hawk eagle shark whale dolphin octopus spider snake frog)
  @qualities ~w(hairy slimy fluffy scaly shiny bumpy soft hard fast slow loud quiet smart silly funny brave shy happy sad angry)

  @doc """
  Generates a funny session name in the format "color-property-animal".
  """
  def generate_name() do
    "#{Enum.random(@colors)}-#{Enum.random(@qualities)}-#{Enum.random(@animals)}"
  end

  @doc """
  Creates a new session and initializes the log file.
  """
  def new(client, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_name())
    log_dir = Path.join([System.user_home!(), ".agent", "sessions"])
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "#{session_id}.json")

    screen_type = Keyword.get(opts, :screen_type, :agent)
    mode_settings = Beamcore.Agent.Chat.ModeSettings.resolve(screen_type)

    workspace_root =
      opts
      |> Keyword.get(:workspace_root, Beamcore.Agent.Tools.PathInput.workspace_root())
      |> Beamcore.Agent.Tools.PathInput.canonical_path()

    workspace_instructions = Beamcore.Agent.Discovery.WorkspaceContext.load(workspace_root)

    system_message =
      cond do
        screen_type == :chat ->
          %{
            role: "system",
            content: Beamcore.Agent.Core.Prompts.chat_agent()
          }

        true ->
          %{
            role: "system",
            content: Beamcore.Agent.Core.Prompts.dev_agent(workspace_instructions, workspace_root)
          }
      end

    roles =
      if roles_opt = Keyword.get(opts, :roles) do
        roles_opt
      else
        %Beamcore.Provider.Selection{
          primary: %{
            provider: mode_settings.provider,
            model: mode_settings.model,
            enabled: true
          },
          fallback: nil
        }
      end

    messages = [system_message]

    session = %__MODULE__{
      messages: messages,
      client: client,
      session_id: session_id,
      log_file: log_file,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      last_prompt_tokens: 0,
      compaction_count: 0,
      workspace_root: workspace_root,
      roles: roles,
      screen_type: screen_type,
      mode_settings: mode_settings
    }

    Enum.reduce(messages, session, fn msg, acc ->
      log(acc, msg)
    end)
  end

  def set_primary_provider(session, provider, model \\ nil) do
    model = model || provider_default_model(provider) || Beamcore.Agent.Chat.API.default_model()
    roles = session.roles || Beamcore.Provider.Selection.default()

    mode_settings =
      session.mode_settings || Beamcore.Agent.Chat.ModeSettings.resolve(session.screen_type)

    %{
      session
      | roles: Beamcore.Provider.Selection.put_primary(roles, provider, model),
        mode_settings: %{mode_settings | provider: provider, model: model},
        client: nil
    }
  end

  defp provider_default_model(provider) do
    case Beamcore.Provider.Registry.get(provider) do
      %{default_model: model} -> model
      _ -> nil
    end
  end

  @doc """
  Logs data to the session file in JSON format.
  """
  def log(session, data) do
    json = Jason.encode!(data)
    File.write!(session.log_file, json <> "\n", [:append])
    session
  end

  # --- Usage ---

  @doc """
  Updates the session's token usage with the usage data from an API response.
  """
  def update_usage(session, %Beamcore.Provider.Usage{} = usage) do
    update_usage(session, Beamcore.Provider.Usage.to_raw_usage(usage))
  end

  def update_usage(session, usage) do
    %{
      session
      | total_prompt_tokens: session.total_prompt_tokens + (usage["prompt_tokens"] || 0),
        total_completion_tokens:
          session.total_completion_tokens + (usage["completion_tokens"] || 0),
        total_tokens: session.total_tokens + (usage["total_tokens"] || 0),
        last_prompt_tokens: usage["prompt_tokens"] || 0
    }
  end

  @doc """
  Returns the current token usage for the session.
  """
  def usage(session) do
    %{
      prompt_tokens: session.total_prompt_tokens,
      completion_tokens: session.total_completion_tokens,
      total_tokens: session.total_tokens,
      last_prompt_tokens: session.last_prompt_tokens || 0
    }
  end

  # --- Compaction delegation ---

  defdelegate compact_history(messages), to: Compaction
  defdelegate summarize_and_rollover(session, messages, pid), to: Compaction

  @doc """
  Prepares messages for an API call: structural cleanup.
  """
  def prepare_for_api(messages) do
    MessageCleaner.clean(messages)
  end

  # --- Message cleaning delegation ---

  defdelegate trim_and_clean_messages(messages, limit),
    to: MessageCleaner,
    as: :trim_and_clean
end
