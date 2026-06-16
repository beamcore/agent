defmodule Beamcore.Agent.Chat.Session do
  @moduledoc """
  Manages chat sessions and persists them to disk.
  """

  alias Beamcore.Agent.Chat.Session.{Compaction, MessageCleaner, Serializer}

  defstruct [
    :messages,
    :client,
    :session_id,
    :log_file,
    :total_prompt_tokens,
    :total_completion_tokens,
    :total_tokens,
    :last_prompt_tokens,
    :needs_compaction,
    :compaction_count,
    :warn_user,
    :session_paused,
    :runtime_caps,
    :workspace_root,
    :roles,
    :screen_type,
    :mode_settings,
    :timeline,
    :state_file,
    :interrupted?
  ]

  @colors ~w(red blue green yellow purple orange pink brown black white gray cyan magenta lime maroon navy olive teal silver gold)
  @animals ~w(cat dog bird fish elephant lion tiger bear wolf fox owl hawk eagle shark whale dolphin octopus spider snake frog)
  @qualities ~w(hairy slimy fluffy scaly shiny bumpy soft hard fast slow loud quiet smart silly funny brave shy happy sad angry)

  @grace_threshold 150_000
  @hard_limit 200_000

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
    state_file = Path.join(log_dir, "#{session_id}.state.json")

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
            content: Beamcore.Agent.Core.Prompts.dev_agent(workspace_instructions)
          }
      end

    runtime_caps = Beamcore.Agent.Chat.ToolRuntime.default()

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
      needs_compaction: false,
      compaction_count: 0,
      warn_user: false,
      session_paused: false,
      runtime_caps: runtime_caps,
      workspace_root: workspace_root,
      roles: roles,
      screen_type: screen_type,
      mode_settings: mode_settings,
      timeline: [],
      state_file: state_file,
      interrupted?: false
    }

    session =
      Enum.reduce(messages, session, fn msg, acc ->
        log(acc, msg)
      end)

    append_timeline(session, :started, "Session started.",
      role: :system,
      title: "Session started",
      metadata: %{
        mode: mode_settings.mode,
        provider: mode_settings.provider,
        model: mode_settings.model
      }
    )
  end

  @doc """
  Resume a saved session state by id.
  """
  def resume(session_id, client, opts \\ []) when is_binary(session_id) do
    log_dir = Path.join([System.user_home!(), ".agent", "sessions"])
    state_file = Path.join(log_dir, "#{session_id}.state.json")

    with {:ok, content} <- File.read(state_file),
         {:ok, data} <- Jason.decode(content) do
      {:ok, Serializer.restore(data, client, opts)}
    else
      {:error, reason} -> {:error, reason}
    end
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

  @doc """
  Appends a timeline event and persists the session state.
  """
  def append_timeline(session, type, summary, attrs \\ []) when is_atom(type) do
    attrs_map = normalize_event_attrs(attrs)

    event = %{
      id:
        "evt-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}",
      type: type,
      role: Map.get(attrs_map, :role, :system),
      title: Map.get(attrs_map, :title) || title_from_type(type),
      summary: summary,
      status: Map.get(attrs_map, :status, :completed),
      metadata: Map.get(attrs_map, :metadata, %{}),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    session = %{session | timeline: (session.timeline || []) ++ [event]}
    save_state(session)

    log(session, %{
      event: "timeline",
      timeline: %{
        "id" => event.id,
        "type" => to_string(event.type),
        "role" => to_string(event.role),
        "title" => event.title,
        "summary" => event.summary,
        "status" => to_string(event.status),
        "metadata" => event.metadata,
        "timestamp" => event.timestamp
      }
    })
  end

  @doc """
  Marks the session as interrupted and appends a timeline event.
  """
  def interrupt(session, reason \\ "Session interrupted.") do
    %{session | interrupted?: true}
    |> append_timeline(:interrupted, reason,
      role: :user,
      title: "Session interrupted"
    )
  end

  @doc """
  Resumes an interrupted session and appends a timeline event.
  """
  def resume_interrupted(session, reason \\ "Session resumed.") do
    %{session | interrupted?: false}
    |> append_timeline(:resumed, reason,
      role: :user,
      title: "Session resumed"
    )
  end

  @doc """
  Persists the current session state to disk.
  """
  def save_state(session) do
    if session.state_file do
      tmp_path = session.state_file <> ".tmp-#{System.unique_integer([:positive])}"
      File.write!(tmp_path, Jason.encode!(Serializer.snapshot(session)))
      File.rename!(tmp_path, session.state_file)
    end

    session
  end

  defp normalize_event_attrs(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize_event_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_event_attrs(_attrs), do: %{}

  defp title_from_type(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  # --- Usage ---

  @doc """
  Updates the session's token usage with the usage data from an API response.
  """
  def update_usage(session, %Beamcore.Provider.Usage{} = usage) do
    update_usage(session, Beamcore.Provider.Usage.to_raw_usage(usage))
  end

  def update_usage(session, usage) do
    last_prompt = usage["prompt_tokens"] || 0

    warn = last_prompt >= @grace_threshold
    paused = last_prompt >= @hard_limit

    %{
      session
      | total_prompt_tokens: session.total_prompt_tokens + (usage["prompt_tokens"] || 0),
        total_completion_tokens:
          session.total_completion_tokens + (usage["completion_tokens"] || 0),
        total_tokens: session.total_tokens + (usage["total_tokens"] || 0),
        last_prompt_tokens: last_prompt,
        needs_compaction: session.needs_compaction || warn,
        warn_user: session.warn_user || warn,
        session_paused: session.session_paused || paused
    }
  end

  @doc """
  Returns true if the session has hit the hard limit and must rollover
  immediately, even mid-tool-chain.
  """
  def needs_rollover_now?(session) do
    (session.last_prompt_tokens || 0) >= @hard_limit
  end

  @doc """
  Returns the current token usage for the session.
  """
  def usage(session) do
    %{
      prompt_tokens: session.total_prompt_tokens,
      completion_tokens: session.total_completion_tokens,
      total_tokens: session.total_tokens,
      last_prompt_tokens: session.last_prompt_tokens || 0,
      needs_compaction: session.needs_compaction || false
    }
  end

  @doc """
  Clears warning and pause flags after compaction.
  """
  def clear_warnings(session) do
    %{session | warn_user: false, session_paused: false, needs_compaction: false}
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
