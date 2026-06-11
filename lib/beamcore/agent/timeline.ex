defmodule Beamcore.Agent.Timeline do
  @moduledoc """
  Durable reversible timeline primitives for Beamcore sessions.

  The timeline is append-only. Rewind and fork change the active checkpoint or
  branch without deleting old events.
  """

  @schema_version 1

  @event_types ~w(
    started model_call tool_call file_change research_stage compression decision
    restore_stage error interrupted rewound forked resumed completed checkpoint_saved failed
  )a

  @roles ~w(agent researcher synthesizer system user)a
  @statuses ~w(started completed failed abandoned)a

  def schema_version, do: @schema_version

  def initial_branch_id, do: "branch-main"

  def initial_branches do
    %{
      initial_branch_id() => %{
        id: initial_branch_id(),
        parent_branch_id: nil,
        from_checkpoint_id: nil,
        status: :started,
        title: "Main branch",
        created_at: now()
      }
    }
  end

  def event(session, attrs) do
    type = safe_atom(Map.get(attrs, :type, :decision), @event_types, :decision)
    role = safe_atom(Map.get(attrs, :role, default_role(type)), @roles, :agent)
    status = safe_atom(Map.get(attrs, :status, :completed), @statuses, :completed)

    %{
      id: Map.get(attrs, :id) || unique_id("evt"),
      session_id: session.session_id,
      branch_id: session.branch_id || initial_branch_id(),
      parent_event_id: Map.get(attrs, :parent_event_id) || last_event_id(session),
      checkpoint_id: Map.get(attrs, :checkpoint_id) || session.active_checkpoint_id,
      type: type,
      role: role,
      title: clean(Map.get(attrs, :title) || title_from_type(type)),
      summary: clean(Map.get(attrs, :summary) || Map.get(attrs, :message) || ""),
      status: status,
      timestamp: Map.get(attrs, :timestamp) || now(),
      reversible: reversible_value(attrs, type),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  def checkpoint(session, event, attrs \\ %{}) do
    checkpoint_id = Map.get(attrs, :id) || unique_id("chk")

    %{
      id: checkpoint_id,
      schema_version: @schema_version,
      session_id: session.session_id,
      branch_id: session.branch_id || initial_branch_id(),
      event_id: event.id,
      mode: to_string(session.screen_type || :agent),
      workflow_stage: clean(Map.get(attrs, :workflow_stage) || workflow_stage(event.type)),
      status: clean(Map.get(attrs, :status) || to_string(event.status)),
      user_request: clean(Map.get(attrs, :user_request) || user_request(session)),
      messages: normalize_messages(session.messages || []),
      workflow_state: Map.get(attrs, :workflow_state, session.intermediate_state || %{}),
      research_state: Map.get(attrs, :research_state, %{}),
      tool_state:
        Map.get(attrs, :tool_state, %{})
        |> Map.put_new(
          "filesystem_journal_position",
          Beamcore.Agent.FilesystemJournal.journal_position(session.workspace_root)
        ),
      filesystem_revision:
        Map.get(attrs, :filesystem_revision) ||
          Beamcore.Agent.FilesystemJournal.revision_summary(
            session.workspace_root,
            checkpoint_id,
            session.branch_id || initial_branch_id(),
            active_filesystem_revision_id(session)
          ),
      changed_files_snapshot_or_patch_refs:
        Map.get(attrs, :changed_files_snapshot_or_patch_refs, changed_files(session)),
      usage: usage(session),
      created_at: now()
    }
  end

  def checkpoint_event(session, checkpoint, summary) do
    event(session, %{
      type: :checkpoint_saved,
      role: :system,
      title: "Checkpoint saved",
      summary: summary,
      status: :completed,
      reversible: true,
      metadata: %{checkpoint_id: checkpoint.id},
      checkpoint_id: checkpoint.id
    })
  end

  def rewind(session, checkpoint_id) do
    case find_checkpoint(session, checkpoint_id) do
      nil ->
        {:error, "Checkpoint '#{checkpoint_id}' was not found."}

      checkpoint ->
        abandoned_branch = session.branch_id

        session =
          session
          |> restore_checkpoint(checkpoint)
          |> abandon_events_after(checkpoint)
          |> mark_branch(abandoned_branch, :abandoned)

        event =
          event(session, %{
            type: :rewound,
            role: :user,
            title: "Rewound to checkpoint",
            summary: "Active state moved back to checkpoint #{checkpoint.id}.",
            status: :completed,
            reversible: false,
            metadata: %{checkpoint_id: checkpoint.id, abandoned_branch_id: abandoned_branch}
          })

        {:ok, %{session | timeline: append_event(session.timeline, event)}}
    end
  end

  def fork(session, checkpoint_id, title \\ nil) do
    case find_checkpoint(session, checkpoint_id) do
      nil ->
        {:error, "Checkpoint '#{checkpoint_id}' was not found."}

      checkpoint ->
        old_branch = session.branch_id
        new_branch = unique_id("branch")

        branches =
          session.branches
          |> ensure_branches()
          |> Map.put(new_branch, %{
            id: new_branch,
            parent_branch_id: old_branch,
            from_checkpoint_id: checkpoint.id,
            status: :started,
            title: title || "Fork from #{checkpoint.id}",
            created_at: now()
          })

        session =
          session
          |> restore_checkpoint(checkpoint)
          |> Map.put(:branch_id, new_branch)
          |> Map.put(:branches, branches)

        event =
          event(session, %{
            type: :forked,
            role: :user,
            title: "Forked timeline branch",
            summary: "Created branch #{new_branch} from checkpoint #{checkpoint.id}.",
            status: :completed,
            reversible: false,
            metadata: %{checkpoint_id: checkpoint.id, source_branch_id: old_branch}
          })

        {:ok, %{session | timeline: append_event(session.timeline, event)}}
    end
  end

  def abandon_branch(session, branch_id, reason \\ "Branch abandoned.") do
    session =
      session
      |> mark_branch(branch_id, :abandoned)
      |> Map.update!(:timeline, fn events ->
        Enum.map(events || [], fn event ->
          if event.branch_id == branch_id and event.status not in [:failed, :abandoned] do
            %{
              event
              | status: :abandoned,
                metadata: Map.put(event.metadata || %{}, :abandoned_reason, reason)
            }
          else
            event
          end
        end)
      end)

    event =
      event(session, %{
        type: :decision,
        role: :user,
        title: "Branch abandoned",
        summary: reason,
        status: :completed,
        reversible: false,
        metadata: %{branch_id: branch_id}
      })

    %{session | timeline: append_event(session.timeline, event)}
  end

  def safe_restore(data) when is_map(data) do
    %{
      timeline: Enum.map(Map.get(data, "timeline", []), &safe_event/1),
      checkpoints: Enum.map(Map.get(data, "checkpoints", []), &safe_checkpoint/1),
      branches: safe_branches(Map.get(data, "branches", %{})),
      branch_id: text(Map.get(data, "branch_id")) || initial_branch_id(),
      active_checkpoint_id: text(Map.get(data, "active_checkpoint_id"))
    }
  end

  def write_atomic!(path, data) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    tmp_path = path <> ".tmp-" <> unique_id("write")
    File.write!(tmp_path, Jason.encode!(data))
    File.rename!(tmp_path, path)
    :ok
  end

  def to_json_event(event), do: stringify_map(event)
  def to_json_checkpoint(checkpoint), do: stringify_map(checkpoint)

  defp safe_event(event) when is_map(event) do
    %{
      id: text(Map.get(event, "id")) || unique_id("evt"),
      session_id: text(Map.get(event, "session_id")),
      branch_id: text(Map.get(event, "branch_id")) || initial_branch_id(),
      parent_event_id: text(Map.get(event, "parent_event_id")),
      checkpoint_id: text(Map.get(event, "checkpoint_id")),
      type: safe_atom(Map.get(event, "type"), @event_types, :decision),
      role: safe_atom(Map.get(event, "role"), @roles, :agent),
      title: text(Map.get(event, "title")) || "Timeline event",
      summary: text(Map.get(event, "summary")) || "",
      status: safe_atom(Map.get(event, "status"), @statuses, :completed),
      timestamp: text(Map.get(event, "timestamp")) || now(),
      reversible: Map.get(event, "reversible") == true,
      metadata: safe_metadata(Map.get(event, "metadata", %{}))
    }
  end

  defp safe_event(_), do: safe_event(%{})

  defp safe_checkpoint(checkpoint) when is_map(checkpoint) do
    %{
      id: text(Map.get(checkpoint, "id")) || unique_id("chk"),
      schema_version: integer(Map.get(checkpoint, "schema_version"), @schema_version),
      session_id: text(Map.get(checkpoint, "session_id")),
      branch_id: text(Map.get(checkpoint, "branch_id")) || initial_branch_id(),
      event_id: text(Map.get(checkpoint, "event_id")),
      mode: text(Map.get(checkpoint, "mode")) || "agent",
      workflow_stage: text(Map.get(checkpoint, "workflow_stage")) || "unknown",
      status: text(Map.get(checkpoint, "status")) || "completed",
      user_request: text(Map.get(checkpoint, "user_request")) || "",
      messages: safe_messages(Map.get(checkpoint, "messages", [])),
      workflow_state: safe_metadata(Map.get(checkpoint, "workflow_state", %{})),
      research_state: safe_metadata(Map.get(checkpoint, "research_state", %{})),
      tool_state: safe_metadata(Map.get(checkpoint, "tool_state", %{})),
      filesystem_revision:
        Beamcore.Agent.FilesystemJournal.safe_restore(
          Map.get(checkpoint, "filesystem_revision", %{})
        ),
      changed_files_snapshot_or_patch_refs:
        safe_list(Map.get(checkpoint, "changed_files_snapshot_or_patch_refs", [])),
      usage: safe_metadata(Map.get(checkpoint, "usage", %{})),
      created_at: text(Map.get(checkpoint, "created_at")) || now()
    }
  end

  defp safe_checkpoint(_), do: safe_checkpoint(%{})

  defp safe_branches(branches) when is_map(branches) do
    Map.new(branches, fn {id, branch} ->
      id = text(id) || initial_branch_id()
      branch = if is_map(branch), do: branch, else: %{}

      {id,
       %{
         id: text(Map.get(branch, "id")) || id,
         parent_branch_id: text(Map.get(branch, "parent_branch_id")),
         from_checkpoint_id: text(Map.get(branch, "from_checkpoint_id")),
         status: safe_atom(Map.get(branch, "status"), @statuses, :started),
         title: text(Map.get(branch, "title")) || id,
         created_at: text(Map.get(branch, "created_at")) || now()
       }}
    end)
    |> ensure_branches()
  end

  defp safe_branches(_), do: initial_branches()

  defp restore_checkpoint(session, checkpoint) do
    %{
      session
      | messages: checkpoint.messages,
        branch_id: checkpoint.branch_id,
        active_checkpoint_id: checkpoint.id,
        intermediate_state: checkpoint.workflow_state || %{},
        total_prompt_tokens:
          get_in(checkpoint, [:usage, "total_prompt_tokens"]) || session.total_prompt_tokens,
        total_completion_tokens:
          get_in(checkpoint, [:usage, "total_completion_tokens"]) ||
            session.total_completion_tokens,
        total_tokens: get_in(checkpoint, [:usage, "total_tokens"]) || session.total_tokens,
        last_prompt_tokens:
          get_in(checkpoint, [:usage, "last_prompt_tokens"]) || session.last_prompt_tokens
    }
  end

  defp abandon_events_after(session, checkpoint) do
    {before_or_at, after_checkpoint} =
      Enum.split_while(session.timeline || [], fn event -> event.id != checkpoint.event_id end)

    {checkpoint_event, later} =
      case after_checkpoint do
        [event | rest] -> {[event], rest}
        [] -> {[], []}
      end

    abandoned =
      Enum.map(later, fn event ->
        if event.branch_id == checkpoint.branch_id and event.status != :failed do
          %{event | status: :abandoned}
        else
          event
        end
      end)

    %{session | timeline: before_or_at ++ checkpoint_event ++ abandoned}
  end

  def find_checkpoint(session, checkpoint_id) do
    Enum.find(session.checkpoints || [], &(&1.id == checkpoint_id))
  end

  defp append_event(events, event), do: (events || []) ++ [event]

  defp last_event_id(session) do
    case List.last(session.timeline || []) do
      nil -> nil
      event -> event.id
    end
  end

  defp ensure_branches(nil), do: initial_branches()
  defp ensure_branches(branches) when map_size(branches) == 0, do: initial_branches()
  defp ensure_branches(branches), do: branches

  defp mark_branch(session, nil, _status), do: session

  defp mark_branch(session, branch_id, status) do
    branches =
      session.branches
      |> ensure_branches()
      |> Map.update(
        branch_id,
        %{
          id: branch_id,
          parent_branch_id: nil,
          from_checkpoint_id: nil,
          status: status,
          title: branch_id,
          created_at: now()
        },
        &%{&1 | status: status}
      )

    %{session | branches: branches}
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn message ->
      Map.new(message, fn {key, value} -> {to_string(key), value} end)
    end)
  end

  defp safe_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      message when is_map(message) ->
        Map.new(message, fn {key, value} -> {to_string(key), value} end)

      value ->
        %{"role" => "system", "content" => inspect(value)}
    end)
  end

  defp safe_messages(_), do: []

  defp changed_files(%{context: %{modified_files: files}}) do
    files
    |> MapSet.to_list()
    |> Enum.map(&%{"path" => &1, "snapshot" => "not captured"})
  end

  defp changed_files(_), do: []

  defp active_filesystem_revision_id(session) do
    session.checkpoints
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(fn checkpoint ->
      case Map.get(checkpoint, :filesystem_revision) do
        %{"revision_id" => id} when is_binary(id) -> id
        %{revision_id: id} when is_binary(id) -> id
        _ -> nil
      end
    end)
  end

  defp usage(session) do
    %{
      "total_prompt_tokens" => session.total_prompt_tokens || 0,
      "total_completion_tokens" => session.total_completion_tokens || 0,
      "total_tokens" => session.total_tokens || 0,
      "last_prompt_tokens" => session.last_prompt_tokens || 0,
      "needs_compaction" => session.needs_compaction || false,
      "compaction_count" => session.compaction_count || 0,
      "correction_count" => session.correction_count || 0
    }
  end

  defp user_request(session) do
    session.messages
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      role = message[:role] || message["role"]
      content = message[:content] || message["content"]
      if role in [:user, "user"] and is_binary(content), do: content
    end)
    |> Kernel.||("")
  end

  defp workflow_stage(:research_stage), do: "research"
  defp workflow_stage(:model_call), do: "model_call"
  defp workflow_stage(:tool_call), do: "tool_call"
  defp workflow_stage(:compression), do: "compression"
  defp workflow_stage(type), do: to_string(type)

  defp default_role(:research_stage), do: :researcher
  defp default_role(:compression), do: :system
  defp default_role(:interrupted), do: :user
  defp default_role(:rewound), do: :user
  defp default_role(:forked), do: :user
  defp default_role(:resumed), do: :user
  defp default_role(_), do: :agent

  defp title_from_type(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp reversible_type?(type),
    do:
      type in [
        :model_call,
        :tool_call,
        :file_change,
        :research_stage,
        :compression,
        :decision,
        :completed
      ]

  defp reversible_value(attrs, type) do
    case Map.get(attrs, :reversible) do
      value when is_boolean(value) -> value
      _ -> reversible_type?(type)
    end
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_atom(value), do: to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp safe_metadata(map) when is_map(map), do: map
  defp safe_metadata(_), do: %{}

  defp safe_list(list) when is_list(list), do: list
  defp safe_list(_), do: []

  defp safe_atom(value, allowed, fallback) when is_atom(value) do
    if value in allowed, do: value, else: fallback
  end

  defp safe_atom(value, allowed, fallback) when is_binary(value) do
    Enum.find(allowed, fallback, &(to_string(&1) == value))
  end

  defp safe_atom(_value, _allowed, fallback), do: fallback

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: to_string(value)
  defp text(value), do: to_string(value)

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value), do: value |> inspect() |> String.trim()

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(value, default) when is_binary(value), do: parse_integer(value, default)
  defp integer(_value, default), do: default

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
