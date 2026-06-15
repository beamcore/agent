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
      "checkpoint_file" => session.checkpoint_file,
      "messages" => stringify_messages(session.messages || []),
      "screen_type" => to_string(session.screen_type || :agent),
      "roles" => stringify_roles(session.roles),
      "timeline" => Enum.map(session.timeline || [], &Beamcore.Agent.Timeline.to_json_event/1),
      "checkpoints" =>
        Enum.map(session.checkpoints || [], &Beamcore.Agent.Timeline.to_json_checkpoint/1),
      "branches" => stringify_branches(session.branches || %{}),
      "branch_id" => session.branch_id,
      "active_checkpoint_id" => session.active_checkpoint_id,
      "usage" => %{
        "total_prompt_tokens" => session.total_prompt_tokens || 0,
        "total_completion_tokens" => session.total_completion_tokens || 0,
        "total_tokens" => session.total_tokens || 0,
        "last_prompt_tokens" => session.last_prompt_tokens || 0,
        "needs_compaction" => session.needs_compaction || false,
        "compaction_count" => session.compaction_count || 0,
        "correction_count" => session.correction_count || 0
      },
      "workspace_root" => session.workspace_root,
      "intermediate_state" => session.intermediate_state || %{},
      "interrupted" => session.interrupted? || false
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
    timeline_state = Beamcore.Agent.Timeline.safe_restore(data)
    usage = Map.get(data, "usage", %{})
    workspace_root = Map.get(data, "workspace_root") || Keyword.get(opts, :workspace_root)
    {language, build_system} = Beamcore.Agent.Discovery.Detector.detect(workspace_root || ".")

    %Beamcore.Agent.Chat.Session{
      messages: safe_messages(Map.get(data, "messages", [])),
      client: client,
      session_id: Map.fetch!(data, "session_id"),
      log_file: Map.get(data, "log_file"),
      state_file: Map.get(data, "state_file"),
      checkpoint_file:
        Map.get(data, "checkpoint_file") ||
          Path.join(
            Path.dirname(Map.get(data, "state_file")),
            "#{Map.fetch!(data, "session_id")}.checkpoints.json"
          ),
      total_prompt_tokens: Map.get(usage, "total_prompt_tokens", 0),
      total_completion_tokens: Map.get(usage, "total_completion_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0),
      last_prompt_tokens: Map.get(usage, "last_prompt_tokens", 0),
      needs_compaction: Map.get(usage, "needs_compaction", false),
      compaction_count: Map.get(usage, "compaction_count", 0),
      correction_count: Map.get(usage, "correction_count", 0),
      runtime_caps:
        if(screen_type == :chat,
          do: Beamcore.Agent.Chat.ToolRuntime.chat(),
          else: nil
        ),
      project_nature: {language, build_system},
      workspace_root: workspace_root,
      context: Beamcore.Agent.Chat.Context.new(language, build_system),
      roles: restore_roles(Map.get(data, "roles"), mode_settings),
      screen_type: screen_type,
      mode_settings: mode_settings,
      timeline: timeline_state.timeline,
      checkpoints: timeline_state.checkpoints,
      branches: timeline_state.branches,
      branch_id: timeline_state.branch_id,
      active_checkpoint_id: timeline_state.active_checkpoint_id,
      intermediate_state: Map.get(data, "intermediate_state", %{}),
      interrupted?: false
    }
    |> Beamcore.Agent.Chat.Session.TimelineOps.append_timeline(:resumed, "Session resumed.",
      role: :system,
      title: "Session resumed",
      reversible: false,
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

  def stringify_roles(nil), do: nil
  def stringify_roles(%Selection{} = roles), do: Map.from_struct(roles)
  def stringify_roles(roles), do: roles

  defp restore_roles(nil, settings) do
    %Selection{
      primary: %{provider: settings.provider, model: settings.model, enabled: true},
      fallback: nil
    }
  end

  defp restore_roles(%{"primary" => primary} = roles, _settings) do
    %Selection{
      primary: safe_selection(primary),
      fallback: safe_selection(Map.get(roles, "fallback"))
    }
  end

  defp restore_roles(%{"primary" => primary, "fallback" => fallback}, _settings) do
    %Selection{
      primary: safe_selection(primary),
      fallback: safe_selection(fallback)
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

  def stringify_branches(branches) do
    Map.new(branches, fn {id, branch} ->
      {id, Beamcore.Agent.Timeline.to_json_event(branch)}
    end)
  end

  defp mode_atom("chat"), do: :chat
  defp mode_atom(_), do: :agent
end
