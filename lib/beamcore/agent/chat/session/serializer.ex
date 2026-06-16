defmodule Beamcore.Agent.Chat.Session.Serializer do
  @moduledoc """
  Handles serialization and deserialization of session state.

  Converts session structs to/from JSON-compatible maps for persistence,
  and manages role selection serialization.
  """

  alias Beamcore.Provider.Selection

  @doc """
  Creates a JSON-serializable snapshot of the session.
  """
  def snapshot(session) do
    %{
      "version" => 1,
      "session_id" => session.session_id,
      "log_file" => session.log_file,
      "state_file" => session.state_file,
      "messages" => stringify_messages(session.messages || []),
      "screen_type" => to_string(session.screen_type || :agent),
      "roles" => stringify_roles(session.roles),
      "timeline" => Enum.map(session.timeline || [], &stringify_event/1),
      "usage" => %{
        "total_prompt_tokens" => session.total_prompt_tokens || 0,
        "total_completion_tokens" => session.total_completion_tokens || 0,
        "total_tokens" => session.total_tokens || 0,
        "last_prompt_tokens" => session.last_prompt_tokens || 0,
        "needs_compaction" => session.needs_compaction || false,
        "compaction_count" => session.compaction_count || 0,
        "warn_user" => session.warn_user || false,
        "session_paused" => session.session_paused || false
      },
      "workspace_root" => session.workspace_root,
      "interrupted?" => session.interrupted? || false
    }
  end

  @doc """
  Restores a session from a decoded JSON map.
  """
  def restore(data, client, opts) do
    screen_type =
      data
      |> Map.get("screen_type", "agent")
      |> mode_atom()

    mode_settings = Beamcore.Agent.Chat.ModeSettings.resolve(screen_type)
    usage = Map.get(data, "usage", %{})
    workspace_root = Map.get(data, "workspace_root") || Keyword.get(opts, :workspace_root)

    timeline =
      data
      |> Map.get("timeline", [])
      |> Enum.map(&safe_event/1)

    %Beamcore.Agent.Chat.Session{
      messages: safe_messages(Map.get(data, "messages", [])),
      client: client,
      session_id: Map.fetch!(data, "session_id"),
      log_file: Map.get(data, "log_file"),
      state_file: Map.get(data, "state_file"),
      total_prompt_tokens: Map.get(usage, "total_prompt_tokens", 0),
      total_completion_tokens: Map.get(usage, "total_completion_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0),
      last_prompt_tokens: Map.get(usage, "last_prompt_tokens", 0),
      needs_compaction: Map.get(usage, "needs_compaction", false),
      compaction_count: Map.get(usage, "compaction_count", 0),
      warn_user: Map.get(usage, "warn_user", false),
      session_paused: Map.get(usage, "session_paused", false),
      runtime_caps:
        if(screen_type == :chat,
          do: Beamcore.Agent.Chat.ToolRuntime.chat(),
          else: Beamcore.Agent.Chat.ToolRuntime.default()
        ),
      workspace_root: workspace_root,
      roles: restore_roles(Map.get(data, "roles"), mode_settings),
      screen_type: screen_type,
      mode_settings: mode_settings,
      timeline: timeline,
      interrupted?: Map.get(data, "interrupted?", false) || Map.get(data, "interrupted", false)
    }
    |> Beamcore.Agent.Chat.Session.append_timeline(:resumed, "Session resumed.",
      role: :system,
      title: "Session resumed",
      metadata: %{session_id: Map.get(data, "session_id")}
    )
  end

  defp stringify_messages(messages) do
    Enum.map(messages, fn message ->
      message
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()
    end)
  end

  defp safe_messages(messages) do
    Enum.map(messages, fn message ->
      Map.new(message, fn {key, value} -> {to_string(key), value} end)
    end)
  end

  defp stringify_event(event) when is_map(event) do
    %{
      "id" => Map.get(event, :id) || Map.get(event, "id"),
      "type" => to_string(Map.get(event, :type) || Map.get(event, "type")),
      "role" => to_string(Map.get(event, :role) || Map.get(event, "role")),
      "title" => Map.get(event, :title) || Map.get(event, "title"),
      "summary" => Map.get(event, :summary) || Map.get(event, "summary"),
      "status" => to_string(Map.get(event, :status) || Map.get(event, "status")),
      "metadata" => Map.get(event, :metadata) || Map.get(event, "metadata") || %{},
      "timestamp" => Map.get(event, :timestamp) || Map.get(event, "timestamp")
    }
  end

  defp safe_event(event) when is_map(event) do
    %{
      id: Map.get(event, "id") || "evt-#{System.unique_integer([:positive])}",
      type: safe_atom(Map.get(event, "type"), :decision),
      role: safe_atom(Map.get(event, "role"), :system),
      title: Map.get(event, "title") || "Timeline event",
      summary: Map.get(event, "summary") || "",
      status: safe_atom(Map.get(event, "status"), :completed),
      metadata: safe_metadata(Map.get(event, "metadata", %{})),
      timestamp: Map.get(event, "timestamp") || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp safe_event(_), do: safe_event(%{})

  @event_types ~w(started model_call tool_call file_change compression decision
    restore_stage error interrupted rewound forked resumed completed checkpoint_saved failed)a

  defp safe_atom(value, fallback) when is_atom(value) do
    if value in @event_types, do: value, else: fallback
  end

  defp safe_atom(value, fallback) when is_binary(value) do
    Enum.find(@event_types, fallback, &(to_string(&1) == value))
  end

  defp safe_atom(_, fallback), do: fallback

  defp safe_metadata(map) when is_map(map), do: map
  defp safe_metadata(_), do: %{}

  @doc false
  def stringify_roles(nil), do: nil
  def stringify_roles(%Selection{} = roles), do: Map.from_struct(roles)
  def stringify_roles(roles), do: roles

  defp restore_roles(nil, settings) do
    %Selection{
      primary: %{provider: settings.provider, model: settings.model, enabled: true},
      fallback: nil
    }
  end

  defp restore_roles(%{"primary" => primary, "fallback" => fallback}, _settings) do
    %Selection{
      primary: safe_selection(primary),
      fallback: safe_selection(fallback)
    }
  end

  defp restore_roles(%{"primary" => primary} = _roles, _settings) do
    %Selection{
      primary: safe_selection(primary),
      fallback: nil
    }
  end

  defp restore_roles(roles, _settings), do: roles

  defp safe_selection(nil), do: nil

  defp safe_selection(selection) do
    %{
      provider: Map.get(selection, "provider") || Map.get(selection, :provider),
      model: Map.get(selection, "model") || Map.get(selection, :model),
      enabled: Map.get(selection, "enabled") || Map.get(selection, :enabled) || false
    }
  end

  defp mode_atom("chat"), do: :chat
  defp mode_atom(_), do: :agent
end
