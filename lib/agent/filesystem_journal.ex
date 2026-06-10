defmodule Beamcore.Agent.FilesystemJournal do
  @moduledoc """
  Provenance journal for agent-owned filesystem mutations.

  The journal records mutations performed through BeamCore's guarded tools. A
  rewind applies inverse operations after a checkpoint boundary and preserves
  external changes when the current bytes no longer match the last agent-written
  state.
  """

  alias Beamcore.Agent.PathSafety
  alias Beamcore.Agent.Timeline
  alias Beamcore.Agent.FilesystemJournal.Server

  @schema_version 1
  @internal_dir ".beamcore"
  @snapshot_dir "snapshots"
  @blob_dir "blobs"
  @recovery_dir "recovery"
  @journal_file "journal.json"

  @max_file_bytes 5 * 1024 * 1024
  @max_operation_bytes 20 * 1024 * 1024
  @max_directory_files 1_000
  @max_total_bytes 100 * 1024 * 1024
  @max_command_scan_files 20_000
  @command_scan_excludes ~w(.beamcore/snapshots .beamcore/recovery .git _build deps node_modules .elixir_ls)

  def schema_version, do: @schema_version
  def restore_id, do: unique_id("restore")

  def internal_relative_paths, do: [".beamcore/snapshots", ".beamcore/recovery"]

  def context do
    Process.get(:beamcore_filesystem_context)
  end

  def with_context(context, fun) when is_function(fun, 0) do
    previous = Process.get(:beamcore_filesystem_context)
    Process.put(:beamcore_filesystem_context, normalize_context(context))

    try do
      fun.()
    after
      restore_context(previous)
    end
  end

  def journal_position(workspace_root \\ PathSafety.workspace_root()) do
    workspace_root = workspace_root || PathSafety.workspace_root()

    workspace_root
    |> read_journal()
    |> Map.get("position", 0)
  end

  def file_state_from_bytes(nil, _mode), do: %{"type" => "absent"}

  def file_state_from_bytes(bytes, mode) when is_binary(bytes) do
    %{
      "type" => "file",
      "content_hash" => sha256(bytes),
      "blob_hash" => sha256(bytes),
      "bytes" => bytes,
      "byte_size" => byte_size(bytes),
      "mode" => mode || 0o644,
      "text" => text_bytes?(bytes)
    }
  end

  def snapshot_state(path, workspace_root \\ PathSafety.workspace_root()) when is_binary(path) do
    with {:ok, relative_path} <- safe_relative(path, workspace_root),
         :ok <- ensure_not_internal(relative_path) do
      snapshot_path(path, workspace_root)
    end
  end

  def revision_summary(workspace_root, checkpoint_id, branch_id, parent_revision_id \\ nil) do
    workspace_root = workspace_root || PathSafety.workspace_root()
    journal = read_journal(workspace_root)
    position = Map.get(journal, "position", 0)

    %{
      "schema_version" => @schema_version,
      "revision_id" => unique_id("fsrev"),
      "checkpoint_id" => checkpoint_id,
      "branch_id" => branch_id,
      "parent_revision_id" => parent_revision_id,
      "journal_position" => position,
      "mutation_count" => position,
      "changed_path_count" => changed_path_count(journal),
      "stored_bytes" => stored_bytes(workspace_root),
      "created_at" => now()
    }
  end

  def record_file_write(path, before_state, after_bytes, opts \\ []) when is_binary(path) do
    context = Keyword.get(opts, :context) || context()

    if context_enabled?(context) do
      workspace_root = context.workspace_root

      with {:ok, relative_path} <- safe_relative(path, workspace_root),
           :ok <- ensure_not_internal(relative_path),
           {:ok, after_state} <- state_from_written_path(path, after_bytes, workspace_root),
           :ok <- validate_size(before_state, after_state) do
        operation =
          if state_exists?(before_state), do: "modify_file", else: "create_file"

        mutation =
          base_mutation(context, operation, Keyword.get(opts, :tool, "unknown"))
          |> Map.merge(%{
            "path" => relative_path,
            "before_state" => persist_state(workspace_root, before_state),
            "after_state" => persist_state(workspace_root, after_state),
            "status" => "completed"
          })

        append_mutation(workspace_root, mutation)
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  def record_remove(path, opts \\ []) when is_binary(path) do
    context = Keyword.get(opts, :context) || context()

    if context_enabled?(context) do
      workspace_root = context.workspace_root

      with {:ok, relative_path} <- safe_relative(path, workspace_root),
           :ok <- ensure_not_internal(relative_path),
           {:ok, before_state} <- snapshot_path(path, workspace_root),
           :ok <- validate_destructive_state(before_state) do
        mutation =
          base_mutation(context, remove_operation(before_state), Keyword.get(opts, :tool, "fs"))
          |> Map.merge(%{
            "path" => relative_path,
            "before_state" => persist_state(workspace_root, before_state),
            "after_state" => %{"type" => "absent"},
            "status" => "prepared"
          })

        {:ok, mutation}
      end
    else
      {:ok, nil}
    end
  end

  def commit_prepared(nil), do: :ok

  def commit_prepared(mutation) when is_map(mutation) do
    workspace_root = mutation["workspace_root"]

    mutation =
      mutation
      |> Map.delete("workspace_root")
      |> Map.put("status", "completed")

    append_mutation(workspace_root, mutation)
  end

  def record_mkdir(path, opts \\ []) when is_binary(path) do
    context = Keyword.get(opts, :context) || context()

    if context_enabled?(context) do
      workspace_root = context.workspace_root

      with {:ok, relative_path} <- safe_relative(path, workspace_root),
           :ok <- ensure_not_internal(relative_path),
           {:ok, after_state} <- snapshot_path(path, workspace_root) do
        mutation =
          base_mutation(context, "create_directory", Keyword.get(opts, :tool, "fs"))
          |> Map.merge(%{
            "path" => relative_path,
            "before_state" => %{"type" => "absent"},
            "after_state" => persist_state(workspace_root, after_state),
            "status" => "completed"
          })

        append_mutation(workspace_root, mutation)
      end
    else
      :ok
    end
  end

  def begin_command_scope(tool, command, workdir, opts \\ [])
      when is_binary(tool) and is_binary(command) and is_binary(workdir) do
    context = Keyword.get(opts, :context) || context()

    if context_enabled?(context) do
      workspace_root = context.workspace_root

      with {:ok, relative_workdir} <- safe_relative(workdir, workspace_root),
           :ok <- ensure_not_internal(relative_workdir),
           {:ok, baseline} <- command_manifest(workdir, workspace_root) do
        {:ok,
         %{
           "operation_id" => unique_id("fscmd"),
           "actor" => "agent",
           "source" => "command",
           "command_kind" => command_kind(tool, command, opts),
           "tool" => tool,
           "command" => command,
           "session_id" => context.session_id,
           "branch_id" => context.branch_id,
           "checkpoint_id" => context.checkpoint_id,
           "generation_id" => context.generation_id,
           "workspace_root" => workspace_root,
           "workdir" => relative_workdir,
           "journal_position" => journal_position(workspace_root),
           "started_at" => now(),
           "baseline" => baseline
         }}
      end
    else
      {:ok, nil}
    end
  end

  def complete_command_scope(nil), do: {:ok, %{"changed_path_count" => 0, "mutations" => []}}

  def complete_command_scope(%{"workspace_root" => workspace_root, "workdir" => workdir} = scope) do
    absolute_workdir = absolute(workspace_root, workdir)

    with {:ok, after_manifest} <- command_manifest(absolute_workdir, workspace_root),
         {:ok, mutations} <-
           command_manifest_mutations(scope, Map.get(scope, "baseline", %{}), after_manifest) do
      Enum.each(mutations, &append_mutation(workspace_root, &1))

      {:ok,
       %{
         "operation_id" => scope["operation_id"],
         "command_kind" => scope["command_kind"],
         "changed_path_count" => length(mutations),
         "mutations" => Enum.map(mutations, &Map.take(&1, ["operation", "path", "target_path"]))
       }}
    end
  end

  def restore_to_checkpoint(_session, nil), do: {:error, "Checkpoint was not found."}

  def restore_to_checkpoint(session, checkpoint) do
    Beamcore.Agent.RestoreCoordinator.restore(session, checkpoint)
  end

  def restore_to_checkpoint_owned(session, checkpoint, opts \\ [])
  def restore_to_checkpoint_owned(_session, nil, _opts), do: {:error, "Checkpoint was not found."}

  def restore_to_checkpoint_owned(session, checkpoint, opts) do
    workspace_root = session.workspace_root || PathSafety.workspace_root()

    Server.transaction(workspace_root, fn ->
      do_restore_to_checkpoint(session, checkpoint, workspace_root, opts)
    end)
  end

  def safe_restore(data) when is_map(data) do
    %{
      "schema_version" => integer(Map.get(data, "schema_version"), @schema_version),
      "revision_id" => text(Map.get(data, "revision_id")),
      "checkpoint_id" => text(Map.get(data, "checkpoint_id")),
      "branch_id" => text(Map.get(data, "branch_id")),
      "parent_revision_id" => text(Map.get(data, "parent_revision_id")),
      "journal_position" => integer(Map.get(data, "journal_position"), 0),
      "mutation_count" => integer(Map.get(data, "mutation_count"), 0),
      "changed_path_count" => integer(Map.get(data, "changed_path_count"), 0),
      "stored_bytes" => integer(Map.get(data, "stored_bytes"), 0),
      "created_at" => text(Map.get(data, "created_at")) || now()
    }
  end

  def safe_restore(_), do: safe_restore(%{})

  def recover_incomplete_restores(nil), do: :ok

  def recover_incomplete_restores(workspace_root) when is_binary(workspace_root) do
    Server.transaction(workspace_root, fn ->
      workspace_root
      |> Path.join(Path.join([@internal_dir, @snapshot_dir, "restores", "*.json"]))
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, ".safety.json"))
      |> Enum.each(fn path ->
        with {:ok, bytes} <- File.read(path),
             {:ok, %{} = data} <- Jason.decode(bytes),
             true <- incomplete_restore_status?(Map.get(data, "status")) do
          recover_restore_intent(workspace_root, path, data)
        else
          _ -> :ok
        end
      end)
    end)

    :ok
  end

  defp incomplete_restore_status?(status)
       when status in [
              "planned",
              "preflighted",
              "safety_revision_saved",
              "applying",
              "verifying",
              "recovering"
            ],
       do: true

  defp incomplete_restore_status?(_status), do: false

  defp recover_restore_intent(_workspace_root, path, %{"status" => status} = data)
       when status in ["planned", "preflighted", "safety_revision_saved"] do
    result = %{
      "status" => "cancelled",
      "operational_failure_count" => 0,
      "operational_failures" => []
    }

    data
    |> Map.put("status", "cancelled")
    |> Map.put("result", result)
    |> Map.put("completed_at", now())
    |> then(&Timeline.write_atomic!(path, &1))

    :ok
  end

  defp recover_restore_intent(workspace_root, path, %{"restore_id" => restore_id} = data) do
    safety_path = safety_revision_path(workspace_root, restore_id)

    result =
      with {:ok, bytes} <- File.read(safety_path),
           {:ok, %{"entries" => entries}} <- Jason.decode(bytes) do
        Enum.each(entries || %{}, fn {rel, state} ->
          restore_safety_state(workspace_root, rel, state)
        end)

        %{
          "status" => "failed_recovered",
          "operational_failure_count" => 1,
          "operational_failures" => [
            %{
              "type" => "operational_failure",
              "reason" =>
                "Restore was interrupted and workspace was recovered to the safety revision."
            }
          ]
        }
      else
        _ ->
          %{
            "status" => "failed_recovery_required",
            "operational_failure_count" => 1,
            "operational_failures" => [
              %{
                "type" => "operational_failure",
                "reason" =>
                  "Restore was interrupted and safety revision recovery could not be completed."
              }
            ]
          }
      end

    data
    |> Map.put("status", result["status"])
    |> Map.put("result", result)
    |> Map.put("completed_at", now())
    |> then(&Timeline.write_atomic!(path, &1))

    :ok
  end

  def exclude_internal_path?(path) when is_binary(path) do
    rel =
      path
      |> Path.expand(PathSafety.workspace_root())
      |> Path.relative_to(PathSafety.workspace_root())

    internal_path?(rel)
  end

  defp do_restore_to_checkpoint(session, checkpoint, workspace_root, opts) do
    target_position = checkpoint_filesystem_position(checkpoint)
    current_position = journal_position(workspace_root)
    progress = Keyword.get(opts, :progress)
    restore_id = Keyword.get(opts, :restore_id) || restore_id()

    if target_position >= current_position do
      result = restore_result(target_position, 0, 0, 0, restore_id)

      emit_restore_progress(progress, session, checkpoint, restore_id, "planned", [], result)
      emit_restore_progress(progress, session, checkpoint, restore_id, "completed", [], result)

      {:ok, result}
    else
      journal = read_journal(workspace_root)

      mutations =
        journal
        |> Map.get("mutations", [])
        |> Enum.filter(fn mutation ->
          integer(Map.get(mutation, "position"), 0) > target_position and
            Map.get(mutation, "branch_id") == session.branch_id and
            Map.get(mutation, "status") == "completed"
        end)
        |> Enum.sort_by(&integer(Map.get(&1, "position"), 0), :desc)

      persist_restore_intent(workspace_root, restore_id, "planned", target_position, mutations)
      emit_restore_progress(progress, session, checkpoint, restore_id, "planned", mutations)

      case validate_restore_inputs(workspace_root, mutations, restore_id) do
        :ok ->
          persist_restore_intent(
            workspace_root,
            restore_id,
            "preflighted",
            target_position,
            mutations
          )

          emit_restore_progress(
            progress,
            session,
            checkpoint,
            restore_id,
            "preflighted",
            mutations
          )

          safety_revision = build_safety_revision!(workspace_root, restore_id, mutations)

          persist_restore_intent(
            workspace_root,
            restore_id,
            "safety_revision_saved",
            target_position,
            mutations,
            safety_revision
          )

          emit_restore_progress(
            progress,
            session,
            checkpoint,
            restore_id,
            "safety_revision_saved",
            mutations
          )

          apply_restore_transaction(
            workspace_root,
            restore_id,
            target_position,
            mutations,
            safety_revision,
            progress,
            session,
            checkpoint
          )

        {:error, failure} ->
          restore_result(target_position, 0, 0, 0, restore_id)
          |> Map.put("operational_failures", [failure])
          |> Map.put("operational_failure_count", 1)
          |> finalize_restore_result()
          |> tap(fn result ->
            persist_restore_result(workspace_root, restore_id, result, mutations)

            emit_restore_progress(
              progress,
              session,
              checkpoint,
              restore_id,
              result["status"],
              mutations,
              result
            )
          end)
          |> then(&{:ok, &1})
      end
    end
  end

  defp undo_mutation(workspace_root, %{"operation" => operation} = mutation, restore_id) do
    case operation do
      "modify_file" -> undo_modify_file(workspace_root, mutation, restore_id)
      "create_file" -> undo_create_path(workspace_root, mutation, restore_id)
      "create_directory" -> undo_create_path(workspace_root, mutation, restore_id)
      "delete_file" -> undo_delete_path(workspace_root, mutation, restore_id)
      "delete_directory" -> undo_delete_path(workspace_root, mutation, restore_id)
      "rename" -> undo_rename(workspace_root, mutation, restore_id)
      _ -> {:ok, %{conflicts: [%{"path" => mutation["path"], "reason" => "not_reversible"}]}}
    end
  end

  defp safe_undo_mutation(workspace_root, mutation, restore_id) do
    undo_mutation(workspace_root, mutation, restore_id)
  rescue
    error ->
      reason = Exception.message(error)
      save_operational_failure(workspace_root, restore_id, mutation, reason)

      {:ok,
       %{
         reverted: 0,
         preserved: 0,
         conflicts: [],
         operational_failures: [operational_failure(mutation, reason)]
       }}
  end

  defp validate_restore_inputs(workspace_root, mutations, restore_id) do
    Enum.reduce_while(mutations, :ok, fn mutation, :ok ->
      case validate_restore_mutation(workspace_root, mutation) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          save_operational_failure(workspace_root, restore_id, mutation, reason)
          {:halt, {:error, operational_failure(mutation, reason)}}
      end
    end)
  end

  defp validate_restore_mutation(workspace_root, mutation) do
    try do
      validate_state_blobs!(workspace_root, mutation["before_state"])
      validate_state_blobs!(workspace_root, mutation["after_state"])
      :ok
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp build_safety_revision!(workspace_root, restore_id, mutations) do
    entries =
      mutations
      |> Enum.flat_map(fn mutation ->
        [mutation["path"], mutation["target_path"]]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn rel ->
        {:ok, state} = snapshot_path(absolute(workspace_root, rel), workspace_root)
        {rel, persist_state(workspace_root, state)}
      end)
      |> Map.new()

    safety_revision = %{
      "schema_version" => @schema_version,
      "restore_id" => restore_id,
      "revision_id" => unique_id("safety"),
      "entries" => entries,
      "created_at" => now()
    }

    Timeline.write_atomic!(safety_revision_path(workspace_root, restore_id), safety_revision)
    safety_revision
  end

  defp apply_restore_transaction(
         workspace_root,
         restore_id,
         target_position,
         mutations,
         safety_revision,
         progress,
         session,
         checkpoint
       ) do
    persist_restore_intent(
      workspace_root,
      restore_id,
      "applying",
      target_position,
      mutations,
      safety_revision
    )

    emit_restore_progress(progress, session, checkpoint, restore_id, "applying", mutations)

    try do
      result =
        mutations
        |> Enum.with_index(1)
        |> Enum.reduce(restore_result(target_position, 0, 0, 0, restore_id), fn {mutation, index},
                                                                                result ->
          result =
            case safe_undo_mutation(workspace_root, mutation, restore_id) do
              {:ok, update} ->
                merge_restore_result(result, update)

              {:error, reason} ->
                add_conflict(result, %{"path" => mutation["path"], "reason" => reason})
            end

          maybe_inject_restore_failure!(:after_operation, index)

          emit_restore_progress(
            progress,
            session,
            checkpoint,
            restore_id,
            "applying",
            mutations,
            %{
              "completed_paths" => index
            }
          )

          result
        end)

      persist_restore_intent(
        workspace_root,
        restore_id,
        "verifying",
        target_position,
        mutations,
        safety_revision
      )

      emit_restore_progress(progress, session, checkpoint, restore_id, "verifying", mutations)

      result = finalize_restore_result(result)
      persist_restore_result(workspace_root, restore_id, result, mutations, safety_revision)

      emit_restore_progress(
        progress,
        session,
        checkpoint,
        restore_id,
        result["status"],
        mutations,
        result
      )

      {:ok, result}
    rescue
      error ->
        reason = Exception.message(error)

        persist_restore_intent(
          workspace_root,
          restore_id,
          "recovering",
          target_position,
          mutations,
          safety_revision
        )

        emit_restore_progress(progress, session, checkpoint, restore_id, "recovering", mutations)

        recover_restore(
          workspace_root,
          restore_id,
          target_position,
          mutations,
          safety_revision,
          reason,
          progress,
          session,
          checkpoint
        )
    end
  end

  defp recover_restore(
         workspace_root,
         restore_id,
         target_position,
         mutations,
         safety_revision,
         reason,
         progress,
         session,
         checkpoint
       ) do
    try do
      maybe_inject_restore_failure!(:during_recovery, 0)

      safety_revision
      |> Map.get("entries", %{})
      |> Enum.sort_by(fn {rel, _state} -> rel end)
      |> Enum.each(fn {rel, state} ->
        restore_safety_state(workspace_root, rel, state)
      end)

      result =
        restore_result(target_position, 0, 0, 0, restore_id)
        |> Map.put("status", "failed_recovered")
        |> Map.put("operational_failures", [
          %{"type" => "operational_failure", "reason" => reason}
        ])
        |> Map.put("operational_failure_count", 1)

      persist_restore_result(workspace_root, restore_id, result, mutations, safety_revision)

      emit_restore_progress(
        progress,
        session,
        checkpoint,
        restore_id,
        "failed_recovered",
        mutations,
        result
      )

      {:ok, result}
    rescue
      recovery_error ->
        result =
          restore_result(target_position, 0, 0, 0, restore_id)
          |> Map.put("status", "failed_recovery_required")
          |> Map.put("operational_failures", [
            %{
              "type" => "operational_failure",
              "reason" => reason,
              "recovery_reason" => Exception.message(recovery_error)
            }
          ])
          |> Map.put("operational_failure_count", 1)

        persist_restore_result(workspace_root, restore_id, result, mutations, safety_revision)

        emit_restore_progress(
          progress,
          session,
          checkpoint,
          restore_id,
          "failed_recovery_required",
          mutations,
          result
        )

        {:ok, result}
    end
  end

  defp emit_restore_progress(
         progress,
         session,
         checkpoint,
         restore_id,
         phase,
         mutations,
         result \\ %{}
       )

  defp emit_restore_progress(
         nil,
         _session,
         _checkpoint,
         _restore_id,
         _phase,
         _mutations,
         _result
       ),
       do: :ok

  defp emit_restore_progress(progress, session, checkpoint, restore_id, phase, mutations, result)
       when is_function(progress, 1) do
    progress.(%{
      phase: phase,
      status: restore_progress_status(phase),
      restore_id: restore_id,
      session_id: session && session.session_id,
      branch_id: session && session.branch_id,
      checkpoint_id: checkpoint && checkpoint.id,
      completed_paths: Map.get(result, "completed_paths", Map.get(result, :completed_paths, 0)),
      total_paths: length(mutations),
      conflict_count: Map.get(result, "conflict_count", 0),
      failure_count: Map.get(result, "operational_failure_count", 0),
      summary: restore_progress_summary(phase, result, length(mutations))
    })
  end

  defp restore_progress_status(phase)
       when phase in ["completed", "completed_with_conflicts", "failed_recovered"],
       do: "completed"

  defp restore_progress_status("failed_recovery_required"), do: "failed"
  defp restore_progress_status(_phase), do: "started"

  defp restore_progress_summary("planned", _result, _total), do: "Restore requested"
  defp restore_progress_summary("preflighted", _result, _total), do: "Restore preflight completed"

  defp restore_progress_summary("safety_revision_saved", _result, _total),
    do: "Safety revision saved"

  defp restore_progress_summary("applying", %{"completed_paths" => done}, total),
    do: "Restoring paths · #{done}/#{total}"

  defp restore_progress_summary("applying", %{completed_paths: done}, total),
    do: "Restoring paths · #{done}/#{total}"

  defp restore_progress_summary("applying", _result, total), do: "Restoring paths · 0/#{total}"
  defp restore_progress_summary("verifying", _result, _total), do: "Verifying restored workspace"
  defp restore_progress_summary("completed", _result, _total), do: "Restore completed"

  defp restore_progress_summary("completed_with_conflicts", result, _total),
    do: "Restore completed with #{Map.get(result, "conflict_count", 0)} conflict(s)"

  defp restore_progress_summary("failed_recovered", _result, _total),
    do: "Restore failed · workspace recovered"

  defp restore_progress_summary("failed_recovery_required", _result, _total),
    do: "Restore failed · recovery required"

  defp restore_progress_summary(phase, _result, _total), do: "Restore #{phase}"

  defp undo_modify_file(workspace_root, mutation, restore_id) do
    path = absolute(workspace_root, mutation["path"])
    before_state = mutation["before_state"]
    after_state = mutation["after_state"]

    with {:ok, current_state} <- snapshot_path(path, workspace_root),
         :ok <- ensure_state_type(current_state, "file") do
      cond do
        state_hash(current_state) == state_hash(after_state) ->
          restore_state(workspace_root, mutation["path"], before_state)
          {:ok, %{reverted: 1, preserved: 0, conflicts: []}}

        text_state?(before_state) and text_state?(after_state) and text_state?(current_state) ->
          three_way_text_rollback(workspace_root, mutation, current_state, restore_id)

        true ->
          save_conflict_versions(workspace_root, restore_id, mutation, current_state, nil)
          {:ok, %{reverted: 0, preserved: 1, conflicts: [conflict(mutation, "external_change")]}}
      end
    else
      {:error, reason} ->
        {:ok, %{reverted: 0, preserved: 0, conflicts: [conflict(mutation, reason)]}}
    end
  end

  defp undo_create_path(workspace_root, mutation, restore_id) do
    path = absolute(workspace_root, mutation["path"])
    after_state = mutation["after_state"]

    with {:ok, current_state} <- snapshot_path(path, workspace_root) do
      cond do
        current_state["type"] == "absent" ->
          {:ok, %{reverted: 0, preserved: 0, conflicts: []}}

        equivalent_state?(current_state, after_state) ->
          remove_agent_created(workspace_root, mutation["path"], current_state)
          {:ok, %{reverted: 1, preserved: 0, conflicts: []}}

        current_state["type"] == "directory" and after_state["type"] == "directory" ->
          remove_agent_owned_directory_entries(
            workspace_root,
            mutation,
            current_state,
            restore_id
          )

        true ->
          save_conflict_versions(workspace_root, restore_id, mutation, current_state, nil)
          {:ok, %{reverted: 0, preserved: 1, conflicts: [conflict(mutation, "external_change")]}}
      end
    end
  end

  defp undo_delete_path(workspace_root, mutation, restore_id) do
    path = absolute(workspace_root, mutation["path"])
    before_state = mutation["before_state"]

    with {:ok, current_state} <- snapshot_path(path, workspace_root) do
      cond do
        current_state["type"] == "absent" ->
          restore_state(workspace_root, mutation["path"], before_state)
          {:ok, %{reverted: 1, preserved: 0, conflicts: []}}

        true ->
          save_conflict_versions(workspace_root, restore_id, mutation, current_state, nil)

          {:ok,
           %{
             reverted: 0,
             preserved: 1,
             conflicts: [conflict(mutation, "path_recreated_externally")]
           }}
      end
    end
  end

  defp undo_rename(workspace_root, mutation, restore_id) do
    delete_mutation =
      mutation
      |> Map.put("operation", "delete_file")
      |> Map.put("path", mutation["path"])

    create_mutation =
      mutation
      |> Map.put("operation", "create_file")
      |> Map.put("path", mutation["target_path"])

    with {:ok, first} <- undo_create_path(workspace_root, create_mutation, restore_id),
         {:ok, second} <- undo_delete_path(workspace_root, delete_mutation, restore_id) do
      {:ok, merge_restore_result(first, second)}
    end
  end

  defp three_way_text_rollback(workspace_root, mutation, current_state, restore_id) do
    base = state_bytes!(workspace_root, mutation["before_state"])
    agent = state_bytes!(workspace_root, mutation["after_state"])
    current = state_bytes!(workspace_root, current_state)

    case inverse_line_merge(base, agent, current) do
      {:ok, proposed} ->
        path = absolute(workspace_root, mutation["path"])
        write_file_atomic!(path, proposed)
        restore_mode(path, mutation["before_state"])
        {:ok, %{reverted: 1, preserved: 1, conflicts: []}}

      {:conflict, proposed} ->
        save_conflict_versions(workspace_root, restore_id, mutation, current_state, proposed)

        {:ok,
         %{
           reverted: 0,
           preserved: 1,
           conflicts: [conflict(mutation, "overlapping_external_change")]
         }}
    end
  end

  def inverse_line_merge(base, agent, current)
      when is_binary(base) and is_binary(agent) and is_binary(current) do
    base_lines = split_lines(base)
    agent_lines = split_lines(agent)
    current_lines = split_lines(current)
    {prefix, base_mid, agent_mid, _suffix} = diff_hunk(base_lines, agent_lines)

    cond do
      base == agent ->
        {:ok, current}

      agent_mid == [] ->
        {:conflict, nil}

      true ->
        case find_unique_sublist(current_lines, agent_mid) do
          {:ok, index} ->
            proposed_lines =
              __MODULE__.ListHelper.replace_at(current_lines, index, length(agent_mid), base_mid)

            {:ok, join_like(proposed_lines, current)}

          :not_found ->
            if Enum.slice(current_lines, prefix, length(agent_mid)) == agent_mid do
              proposed_lines =
                __MODULE__.ListHelper.replace_at(
                  current_lines,
                  prefix,
                  length(agent_mid),
                  base_mid
                )

              {:ok, join_like(proposed_lines, current)}
            else
              {:conflict, nil}
            end

          :ambiguous ->
            {:conflict, nil}
        end
    end
  end

  defp remove_agent_owned_directory_entries(workspace_root, mutation, current_state, restore_id) do
    after_state = mutation["after_state"]
    after_entries = Map.get(after_state, "entries", %{})
    current_entries = Map.get(current_state, "entries", %{})

    {safe, conflicts} =
      Enum.reduce(after_entries, {[], []}, fn {rel, after_entry}, {safe, conflicts} ->
        current_entry = Map.get(current_entries, rel)

        cond do
          is_nil(current_entry) ->
            {safe, conflicts}

          equivalent_state?(current_entry, after_entry) ->
            {[rel | safe], conflicts}

          true ->
            save_entry_conflict(
              workspace_root,
              restore_id,
              mutation,
              rel,
              current_entry,
              after_entry
            )

            {safe, [conflict(%{"path" => rel}, "external_change") | conflicts]}
        end
      end)

    Enum.each(safe, fn rel ->
      remove_path(absolute(workspace_root, rel))
    end)

    remove_empty_directories_under(absolute(workspace_root, mutation["path"]), workspace_root)

    {:ok, %{reverted: length(safe), preserved: length(conflicts), conflicts: conflicts}}
  end

  defp remove_agent_created(workspace_root, relative_path, %{"type" => "directory"}) do
    path = absolute(workspace_root, relative_path)
    File.rm_rf!(path)
  end

  defp remove_agent_created(workspace_root, relative_path, _state) do
    remove_path(absolute(workspace_root, relative_path))
  end

  defp restore_state(_workspace_root, _relative_path, %{"type" => "absent"}), do: :ok

  defp restore_state(workspace_root, relative_path, %{"type" => "file"} = state) do
    path = absolute(workspace_root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    write_file_atomic!(path, state_bytes!(workspace_root, state))
    restore_mode(path, state)
  end

  defp restore_state(workspace_root, relative_path, %{"type" => "symlink"} = state) do
    path = absolute(workspace_root, relative_path)
    target = Map.get(state, "target", "")
    File.mkdir_p!(Path.dirname(path))
    remove_path(path)

    if symlink_target_allowed?(path, target, workspace_root) do
      File.ln_s!(target, path)
      :ok
    else
      raise "symlink target is outside workspace"
    end
  end

  defp restore_state(workspace_root, relative_path, %{"type" => "directory"} = state) do
    path = absolute(workspace_root, relative_path)
    File.mkdir_p!(path)
    restore_mode(path, state)

    state
    |> Map.get("entries", %{})
    |> Enum.sort_by(fn {rel, entry} ->
      {entry["type"] != "directory", rel}
    end)
    |> Enum.each(fn {rel, entry} ->
      restore_state(workspace_root, rel, entry)
    end)
  end

  defp restore_safety_state(workspace_root, relative_path, %{"type" => "absent"}) do
    remove_path(absolute(workspace_root, relative_path))
  end

  defp restore_safety_state(workspace_root, relative_path, state) do
    restore_state(workspace_root, relative_path, state)
  end

  defp snapshot_path(path, workspace_root) do
    cond do
      not File.exists?(path) and not symlink?(path) ->
        {:ok, %{"type" => "absent"}}

      symlink?(path) ->
        snapshot_symlink(path, workspace_root)

      File.dir?(path) ->
        snapshot_directory(path, workspace_root)

      File.regular?(path) ->
        snapshot_file(path)

      true ->
        {:error, "unsupported path type"}
    end
  end

  defp snapshot_file(path) do
    with {:ok, stat} <- File.stat(path, time: :posix) do
      max_bytes = limit(:max_file_bytes, @max_file_bytes)

      if stat.size > max_bytes do
        {:ok,
         %{
           "type" => "file",
           "mode" => mode_bits(stat.mode),
           "content_hash" => sha256("large_file:#{path}:#{stat.size}:#{inspect(stat.mtime)}"),
           "blob_hash" => nil,
           "bytes" => nil,
           "byte_size" => stat.size,
           "text" => false,
           "too_large" => true
         }}
      else
        with {:ok, bytes} <- File.read(path) do
          {:ok,
           %{
             "type" => "file",
             "content_hash" => sha256(bytes),
             "blob_hash" => sha256(bytes),
             "bytes" => bytes,
             "byte_size" => byte_size(bytes),
             "mode" => mode_bits(stat.mode),
             "text" => text_bytes?(bytes)
           }}
        end
      end
    end
  end

  defp snapshot_symlink(path, workspace_root) do
    with {:ok, target} <- File.read_link(path),
         true <- symlink_target_allowed?(path, target, workspace_root),
         {:ok, stat} <- File.lstat(path, time: :posix) do
      {:ok,
       %{
         "type" => "symlink",
         "target" => target,
         "mode" => mode_bits(stat.mode)
       }}
    else
      false -> {:error, "symlink target is outside workspace"}
      {:error, reason} -> {:error, "cannot read symlink: #{reason}"}
    end
  end

  defp snapshot_directory(path, workspace_root) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, entries} <- directory_entries(path, workspace_root) do
      {:ok,
       %{
         "type" => "directory",
         "mode" => mode_bits(stat.mode),
         "entries" => entries
       }}
    end
  end

  defp command_manifest(workdir, workspace_root) do
    with {:ok, root_rel} <- safe_relative(workdir, workspace_root),
         :ok <- ensure_not_internal(root_rel) do
      paths =
        workdir
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.reject(&command_scan_excluded?(&1, workspace_root))

      with :ok <- validate_command_scan_count(paths) do
        Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
          with {:ok, rel} <- safe_relative(path, workspace_root),
               {:ok, state} <- command_entry_state(path, workspace_root) do
            {:cont, {:ok, Map.put(acc, rel, state)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp command_entry_state(path, workspace_root) do
    cond do
      symlink?(path) ->
        snapshot_symlink(path, workspace_root)

      File.dir?(path) ->
        with {:ok, stat} <- File.stat(path, time: :posix) do
          {:ok, %{"type" => "directory", "mode" => mode_bits(stat.mode), "entries" => %{}}}
        end

      File.regular?(path) ->
        snapshot_file(path)

      true ->
        {:error, "unsupported command output path type"}
    end
  end

  defp command_manifest_mutations(scope, before, after_manifest) do
    paths =
      (Map.keys(before) ++ Map.keys(after_manifest))
      |> Enum.uniq()
      |> Enum.sort()

    paths
    |> Enum.reduce_while({:ok, []}, fn rel, {:ok, acc} ->
      before_state = Map.get(before, rel, %{"type" => "absent"})
      after_state = Map.get(after_manifest, rel, %{"type" => "absent"})

      cond do
        equivalent_state?(before_state, after_state) ->
          {:cont, {:ok, acc}}

        before_state["type"] == "directory" and after_state["type"] == "directory" ->
          {:cont, {:ok, acc}}

        true ->
          case command_mutation(scope, rel, before_state, after_state) do
            {:ok, mutation} -> {:cont, {:ok, [mutation | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, mutations} -> {:ok, Enum.reverse(mutations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp command_mutation(scope, rel, before_state, after_state) do
    workspace_root = scope["workspace_root"]

    with :ok <- validate_size(before_state, after_state) do
      mutation =
        command_base_mutation(scope, command_operation(before_state, after_state))
        |> Map.merge(%{
          "path" => rel,
          "before_state" => persist_state(workspace_root, before_state),
          "after_state" => persist_state(workspace_root, after_state),
          "status" => "completed"
        })

      {:ok, mutation}
    end
  end

  defp command_base_mutation(scope, operation) do
    %{
      "operation_id" => unique_id("fsmut"),
      "parent_operation_id" => scope["operation_id"],
      "actor" => "agent",
      "source" => "command",
      "command_kind" => scope["command_kind"],
      "session_id" => scope["session_id"],
      "branch_id" => scope["branch_id"],
      "checkpoint_id" => scope["checkpoint_id"],
      "tool" => scope["tool"],
      "command" => scope["command"],
      "operation" => operation,
      "generation_id" => scope["generation_id"],
      "workspace_root" => scope["workspace_root"],
      "started_at" => scope["started_at"],
      "completed_at" => now()
    }
  end

  defp command_operation(%{"type" => "absent"}, %{"type" => "file"}), do: "create_file"
  defp command_operation(%{"type" => "absent"}, %{"type" => "symlink"}), do: "create_file"
  defp command_operation(%{"type" => "absent"}, %{"type" => "directory"}), do: "create_directory"
  defp command_operation(%{"type" => "file"}, %{"type" => "absent"}), do: "delete_file"
  defp command_operation(%{"type" => "symlink"}, %{"type" => "absent"}), do: "delete_file"
  defp command_operation(%{"type" => "directory"}, %{"type" => "absent"}), do: "delete_directory"
  defp command_operation(%{"type" => "directory"}, %{"type" => "directory"}), do: "modify_file"
  defp command_operation(_before, _after), do: "modify_file"

  defp command_kind(_tool, _command, opts) do
    opts
    |> Keyword.get(:command_kind, Keyword.get(opts, :classification, []))
    |> normalize_command_kind()
  end

  defp normalize_command_kind(kind) when is_binary(kind), do: kind

  defp normalize_command_kind(kinds) when is_list(kinds) do
    cond do
      "formatter" in kinds or "format" in kinds -> "formatter"
      "generator" in kinds or "codegen" in kinds -> "generator"
      "git" in kinds -> "git"
      true -> "validation"
    end
  end

  defp normalize_command_kind(_), do: "validation"

  defp command_scan_excluded?(path, workspace_root) do
    case safe_relative(path, workspace_root) do
      {:ok, rel} ->
        normalized = rel |> Path.split() |> Enum.join("/")

        Enum.any?(@command_scan_excludes, fn excluded ->
          normalized == excluded or String.starts_with?(normalized, excluded <> "/")
        end)

      _ ->
        true
    end
  end

  defp directory_entries(path, workspace_root) do
    files =
      path
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&internal_absolute?(&1, workspace_root))

    with :ok <- validate_directory_count(files) do
      Enum.reduce_while(files, {:ok, %{}}, fn child, {:ok, acc} ->
        with {:ok, rel} <- safe_relative(child, workspace_root),
             {:ok, state} <- snapshot_path(child, workspace_root) do
          {:cont, {:ok, Map.put(acc, rel, state)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp state_from_written_path(path, bytes, workspace_root) do
    cond do
      symlink?(path) or File.dir?(path) ->
        snapshot_path(path, workspace_root)

      true ->
        with :ok <- validate_file_size(bytes),
             {:ok, stat} <- File.stat(path, time: :posix) do
          {:ok,
           %{
             "type" => "file",
             "content_hash" => sha256(bytes),
             "blob_hash" => sha256(bytes),
             "bytes" => bytes,
             "byte_size" => byte_size(bytes),
             "mode" => mode_bits(stat.mode),
             "text" => text_bytes?(bytes)
           }}
        end
    end
  end

  defp persist_state(_workspace_root, %{"type" => "absent"} = state), do: state

  defp persist_state(workspace_root, %{"type" => "file", "blob_hash" => hash} = state) do
    # The caller may have built the state from current bytes; persist them now.
    state =
      case Map.get(state, "bytes") do
        bytes when is_binary(bytes) ->
          write_blob!(workspace_root, hash, bytes)
          Map.delete(state, "bytes")

        _ ->
          state
      end

    state
  end

  defp persist_state(workspace_root, %{"type" => "directory", "entries" => entries} = state) do
    entries =
      Map.new(entries, fn {rel, entry} ->
        {rel, persist_state(workspace_root, entry)}
      end)

    %{state | "entries" => entries}
  end

  defp persist_state(_workspace_root, state), do: state

  defp read_journal(workspace_root) do
    path = journal_path(workspace_root)

    with {:ok, bytes} <- File.read(path),
         {:ok, data} <- Jason.decode(bytes),
         true <- is_map(data) do
      %{
        "schema_version" => integer(Map.get(data, "schema_version"), @schema_version),
        "position" => integer(Map.get(data, "position"), 0),
        "mutations" => safe_mutations(Map.get(data, "mutations", []))
      }
    else
      _ -> %{"schema_version" => @schema_version, "position" => 0, "mutations" => []}
    end
  end

  defp append_mutation(workspace_root, mutation) do
    Server.transaction(workspace_root, fn ->
      append_mutation_unlocked(workspace_root, mutation)
    end)
  end

  defp append_mutation_unlocked(workspace_root, mutation) do
    File.mkdir_p!(blob_dir(workspace_root))
    journal = read_journal(workspace_root)
    position = Map.get(journal, "position", 0) + 1

    mutation =
      mutation
      |> Map.put("schema_version", @schema_version)
      |> Map.put("position", position)
      |> Map.put("created_at", now())

    journal =
      journal
      |> Map.put("position", position)
      |> Map.update!("mutations", &(&1 ++ [mutation]))

    Timeline.write_atomic!(journal_path(workspace_root), journal)
  end

  defp persist_restore_intent(
         workspace_root,
         restore_id,
         status,
         target_position,
         mutations,
         safety_revision \\ nil
       ) do
    data = restore_intent_data(restore_id, status, target_position, mutations, safety_revision)
    Timeline.write_atomic!(restore_intent_path(workspace_root, restore_id), data)
  end

  defp persist_restore_result(
         workspace_root,
         restore_id,
         result,
         mutations,
         safety_revision \\ nil
       ) do
    data =
      restore_intent_data(
        restore_id,
        result["status"],
        result["target_journal_position"],
        mutations,
        safety_revision
      )
      |> Map.put("result", result)
      |> Map.put("completed_at", now())

    Timeline.write_atomic!(restore_intent_path(workspace_root, restore_id), data)
  end

  defp restore_intent_data(restore_id, status, target_position, mutations, safety_revision) do
    %{
      "schema_version" => @schema_version,
      "restore_id" => restore_id,
      "status" => status,
      "target_journal_position" => target_position,
      "mutation_operation_ids" => Enum.map(mutations, & &1["operation_id"]),
      "safety_revision_id" => safety_revision && safety_revision["revision_id"],
      "updated_at" => now()
    }
  end

  defp maybe_inject_restore_failure!(phase, index) do
    if Application.get_env(:agent, :enable_restore_failure_injection, false) do
      failures =
        Application.get_env(:agent, :filesystem_journal_restore_failure)
        |> List.wrap()

      case Enum.find(failures, &matching_restore_failure?(&1, phase, index)) do
        {^phase, ^index, reason} -> raise to_string(reason)
        {^phase, :any, reason} -> raise to_string(reason)
        _ -> :ok
      end
    end
  end

  defp matching_restore_failure?({phase, index, _reason}, phase, index), do: true
  defp matching_restore_failure?({phase, :any, _reason}, phase, _index), do: true
  defp matching_restore_failure?(_failure, _phase, _index), do: false

  defp safe_mutations(mutations) when is_list(mutations) do
    Enum.filter(mutations, &is_map/1)
  end

  defp safe_mutations(_), do: []

  defp base_mutation(context, operation, tool) do
    %{
      "operation_id" => unique_id("fsmut"),
      "actor" => "agent",
      "session_id" => context.session_id,
      "branch_id" => context.branch_id,
      "checkpoint_id" => context.checkpoint_id,
      "tool" => tool,
      "operation" => operation,
      "generation_id" => context.generation_id,
      "workspace_root" => context.workspace_root
    }
  end

  defp normalize_context(nil), do: nil

  defp normalize_context(context) when is_map(context) do
    %{
      session_id: text(context[:session_id] || context["session_id"]),
      branch_id: text(context[:branch_id] || context["branch_id"]),
      checkpoint_id: text(context[:checkpoint_id] || context["checkpoint_id"]),
      generation_id: text(context[:generation_id] || context["generation_id"]),
      workspace_root:
        text(context[:workspace_root] || context["workspace_root"]) ||
          PathSafety.workspace_root()
    }
  end

  defp context_enabled?(%{session_id: session_id, branch_id: branch_id, workspace_root: root})
       when is_binary(session_id) and is_binary(branch_id) and is_binary(root),
       do: true

  defp context_enabled?(_), do: false

  defp restore_context(nil), do: Process.delete(:beamcore_filesystem_context)
  defp restore_context(previous), do: Process.put(:beamcore_filesystem_context, previous)

  defp checkpoint_filesystem_position(%{filesystem_revision: %{} = revision}) do
    integer(revision["journal_position"] || revision[:journal_position], 0)
  end

  defp checkpoint_filesystem_position(%{tool_state: %{} = tool_state}) do
    integer(
      tool_state["filesystem_journal_position"] || tool_state[:filesystem_journal_position],
      0
    )
  end

  defp checkpoint_filesystem_position(_), do: 0

  defp validate_destructive_state(%{"type" => "absent"}), do: {:error, "path does not exist"}

  defp validate_destructive_state(%{"type" => "directory", "entries" => entries}),
    do: validate_directory_count(Map.keys(entries))

  defp validate_destructive_state(%{"type" => "file"} = state),
    do: validate_file_state_size(state)

  defp validate_destructive_state(_), do: :ok

  defp validate_size(before_state, after_state) do
    cond do
      too_large?(before_state) or too_large?(after_state) ->
        {:error, "snapshot exceeds BEAMCORE_SNAPSHOT_MAX_FILE_BYTES"}

      true ->
        total = state_size(before_state) + state_size(after_state)

        cond do
          total > limit(:max_operation_bytes, @max_operation_bytes) ->
            {:error, "snapshot operation exceeds BEAMCORE_SNAPSHOT_MAX_OPERATION_BYTES"}

          total > limit(:max_total_bytes, @max_total_bytes) ->
            {:error, "snapshot operation exceeds BEAMCORE_SNAPSHOT_MAX_TOTAL_BYTES"}

          true ->
            :ok
        end
    end
  end

  defp too_large?(%{"too_large" => true}), do: true
  defp too_large?(%{"type" => "directory", "entries" => entries}) do
    Enum.any?(entries, fn {_rel, entry} -> too_large?(entry) end)
  end
  defp too_large?(_), do: false

  defp validate_file_state_size(state) do
    if state_size(state) > limit(:max_file_bytes, @max_file_bytes),
      do: {:error, "snapshot exceeds BEAMCORE_SNAPSHOT_MAX_FILE_BYTES"},
      else: :ok
  end

  defp validate_file_size(bytes) do
    if byte_size(bytes) > limit(:max_file_bytes, @max_file_bytes),
      do: {:error, "snapshot exceeds BEAMCORE_SNAPSHOT_MAX_FILE_BYTES"},
      else: :ok
  end

  defp validate_directory_count(files) do
    if length(files) > limit(:max_directory_files, @max_directory_files),
      do: {:error, "snapshot exceeds BEAMCORE_SNAPSHOT_MAX_DIRECTORY_FILES"},
      else: :ok
  end

  defp validate_command_scan_count(files) do
    if length(files) > limit(:max_command_scan_files, @max_command_scan_files),
      do: {:error, "command attribution exceeds BEAMCORE_SNAPSHOT_MAX_COMMAND_SCAN_FILES"},
      else: :ok
  end

  defp limit(key, default) do
    env =
      key
      |> to_string()
      |> String.upcase()
      |> then(&"BEAMCORE_SNAPSHOT_#{String.replace_prefix(&1, "MAX_", "MAX_")}")

    case System.get_env(env) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _ -> Application.get_env(:agent, key, default)
        end

      _ ->
        Application.get_env(:agent, key, default)
    end
  end

  defp state_size(%{"type" => "file", "byte_size" => size}) when is_integer(size), do: size

  defp state_size(%{"type" => "directory", "entries" => entries}) do
    entries
    |> Map.values()
    |> Enum.map(&state_size/1)
    |> Enum.sum()
  end

  defp state_size(_), do: 0

  defp changed_path_count(journal) do
    journal
    |> Map.get("mutations", [])
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp stored_bytes(workspace_root) do
    blob_dir(workspace_root)
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, stat} -> stat.size
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp state_bytes!(_workspace_root, %{"bytes" => bytes}) when is_binary(bytes), do: bytes

  defp state_bytes!(workspace_root, %{"blob_hash" => hash}) do
    bytes = File.read!(blob_path(workspace_root, hash))

    if sha256(bytes) == hash do
      bytes
    else
      raise "corrupt blob #{hash}: content hash mismatch"
    end
  end

  defp validate_state_blobs!(workspace_root, %{"type" => "file"} = state) do
    state_bytes!(workspace_root, state)
    :ok
  end

  defp validate_state_blobs!(workspace_root, %{"type" => "directory", "entries" => entries}) do
    Enum.each(entries || %{}, fn {_rel, entry} ->
      validate_state_blobs!(workspace_root, entry)
    end)
  end

  defp validate_state_blobs!(_workspace_root, _state), do: :ok

  defp write_blob!(workspace_root, hash, bytes) do
    path = blob_path(workspace_root, hash)

    unless File.exists?(path) do
      write_file_atomic!(path, bytes)
    end
  end

  defp save_conflict_versions(workspace_root, restore_id, mutation, current_state, proposed) do
    base = recovery_base(workspace_root, restore_id)
    rel = mutation["path"]

    save_recovery_state(base, "current", rel, workspace_root, current_state)
    save_recovery_state(base, "checkpoint", rel, workspace_root, mutation["before_state"])
    save_recovery_state(base, "agent-after", rel, workspace_root, mutation["after_state"])

    if is_binary(proposed) do
      write_file_atomic!(Path.join([base, "proposed", rel]), proposed)
    end
  end

  defp save_operational_failure(workspace_root, restore_id, mutation, reason) do
    base = recovery_base(workspace_root, restore_id)
    path = Path.join([base, "restore-failures", "#{mutation["operation_id"] || "unknown"}.txt"])

    write_file_atomic!(
      path,
      "path: #{mutation["path"]}\noperation: #{mutation["operation"]}\nreason: #{reason}\n"
    )
  end

  defp save_entry_conflict(workspace_root, restore_id, mutation, rel, current_entry, after_entry) do
    base = recovery_base(workspace_root, restore_id)
    save_recovery_state(base, "current", rel, workspace_root, current_entry)
    save_recovery_state(base, "agent-after", rel, workspace_root, after_entry)
    save_recovery_state(base, "checkpoint", rel, workspace_root, mutation["before_state"])
  end

  defp save_recovery_state(_base, _kind, _rel, _workspace_root, nil), do: :ok
  defp save_recovery_state(_base, _kind, _rel, _workspace_root, %{"type" => "absent"}), do: :ok

  defp save_recovery_state(base, kind, rel, workspace_root, %{"type" => "file"} = state) do
    write_file_atomic!(Path.join([base, kind, rel]), state_bytes!(workspace_root, state))
  end

  defp save_recovery_state(base, kind, rel, workspace_root, %{"type" => "directory"} = state) do
    File.mkdir_p!(Path.join([base, kind, rel]))

    state
    |> Map.get("entries", %{})
    |> Enum.each(fn {entry_rel, entry} ->
      save_recovery_state(base, kind, entry_rel, workspace_root, entry)
    end)
  end

  defp save_recovery_state(base, kind, rel, _workspace_root, %{"type" => "symlink"} = state) do
    path = Path.join([base, kind, rel <> ".symlink.txt"])
    write_file_atomic!(path, Map.get(state, "target", ""))
  end

  defp conflict(mutation, reason) do
    %{
      "path" => mutation["path"],
      "reason" => reason,
      "operation_id" => mutation["operation_id"]
    }
  end

  defp restore_result(position, reverted, preserved, conflict_count, restore_id) do
    %{
      "target_journal_position" => position,
      "reverted_mutations" => reverted,
      "preserved_external_changes" => preserved,
      "conflict_count" => conflict_count,
      "conflicts" => [],
      "operational_failure_count" => 0,
      "operational_failures" => [],
      "recovery_id" => restore_id,
      "status" => "planned"
    }
  end

  defp merge_restore_result(result, update) do
    conflicts = Map.get(update, :conflicts, []) ++ Map.get(result, "conflicts", [])

    failures =
      Map.get(update, :operational_failures, []) ++ Map.get(result, "operational_failures", [])

    result
    |> Map.update!("reverted_mutations", &(&1 + Map.get(update, :reverted, 0)))
    |> Map.update!("preserved_external_changes", &(&1 + Map.get(update, :preserved, 0)))
    |> Map.put("conflicts", conflicts)
    |> Map.put("conflict_count", length(conflicts))
    |> Map.put("operational_failures", failures)
    |> Map.put("operational_failure_count", length(failures))
  end

  defp add_conflict(result, conflict) do
    conflicts = [conflict | Map.get(result, "conflicts", [])]

    result
    |> Map.put("conflicts", conflicts)
    |> Map.put("conflict_count", length(conflicts))
  end

  defp finalize_restore_result(%{"operational_failure_count" => count} = result) when count > 0,
    do: %{result | "status" => "failed_recovery_required"}

  defp finalize_restore_result(%{"conflict_count" => count} = result) when count > 0,
    do: %{result | "status" => "completed_with_conflicts"}

  defp finalize_restore_result(result), do: %{result | "status" => "completed"}

  defp operational_failure(mutation, reason) do
    %{
      "path" => mutation["path"],
      "reason" => reason,
      "operation_id" => mutation["operation_id"],
      "type" => "operational_failure"
    }
  end

  defp equivalent_state?(%{"type" => "directory"} = current, %{"type" => "directory"} = expected) do
    current_entries = Map.get(current, "entries", %{})
    expected_entries = Map.get(expected, "entries", %{})

    Map.keys(current_entries) == Map.keys(expected_entries) and
      Enum.all?(expected_entries, fn {rel, state} ->
        equivalent_state?(Map.get(current_entries, rel), state)
      end)
  end

  defp equivalent_state?(current, expected),
    do: state_identity(current) == state_identity(expected)

  defp state_identity(nil), do: nil
  defp state_identity(%{"type" => "file"} = state), do: {"file", state_hash(state), state["mode"]}
  defp state_identity(%{"type" => "symlink"} = state), do: {"symlink", state["target"]}
  defp state_identity(%{"type" => type}), do: {type}

  defp state_hash(%{"content_hash" => hash}), do: hash
  defp state_hash(_), do: nil

  defp text_state?(%{"type" => "file", "text" => true}), do: true
  defp text_state?(_), do: false

  defp ensure_state_type(%{"type" => type}, type), do: :ok

  defp ensure_state_type(%{"type" => type}, expected),
    do: {:error, "expected #{expected}, found #{type}"}

  defp state_exists?(%{"type" => "absent"}), do: false
  defp state_exists?(nil), do: false
  defp state_exists?(_), do: true

  defp remove_operation(%{"type" => "directory"}), do: "delete_directory"
  defp remove_operation(%{"type" => "file"}), do: "delete_file"
  defp remove_operation(%{"type" => "symlink"}), do: "delete_file"

  defp remove_path(path) do
    if File.dir?(path) and not symlink?(path), do: File.rm_rf!(path), else: File.rm(path)
  end

  defp remove_empty_directories_under(path, workspace_root) do
    if File.dir?(path) and path != workspace_root do
      path
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.each(fn dir ->
        case File.ls(dir) do
          {:ok, []} -> File.rmdir(dir)
          _ -> :ok
        end
      end)

      case File.ls(path) do
        {:ok, []} -> File.rmdir(path)
        _ -> :ok
      end
    end
  end

  defp write_file_atomic!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-" <> unique_id("write")

    try do
      File.write!(tmp, bytes)
      File.rename!(tmp, path)
    after
      File.rm(tmp)
    end
  end

  defp restore_mode(path, %{"mode" => mode}) when is_integer(mode), do: File.chmod(path, mode)
  defp restore_mode(_path, _state), do: :ok

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp symlink_target_allowed?(path, target, workspace_root) do
    resolved =
      if Path.type(target) == :absolute do
        Path.expand(target)
      else
        path |> Path.dirname() |> Path.join(target) |> Path.expand()
      end

    resolved == workspace_root or String.starts_with?(resolved, workspace_root <> "/")
  end

  defp absolute(workspace_root, relative_path), do: Path.expand(relative_path, workspace_root)

  defp safe_relative(path, workspace_root) do
    relative = path |> Path.expand() |> Path.relative_to(workspace_root)

    cond do
      Path.type(relative) == :absolute ->
        {:error, "path outside workspace"}

      ".." in Path.split(relative) ->
        {:error, "path outside workspace"}

      true ->
        {:ok, relative}
    end
  end

  defp ensure_not_internal(relative_path) do
    if internal_path?(relative_path),
      do: {:error, "BeamCore internal snapshot paths are not agent-writable"},
      else: :ok
  end

  defp internal_absolute?(path, workspace_root) do
    path
    |> Path.relative_to(workspace_root)
    |> internal_path?()
  end

  defp internal_path?(relative_path) do
    normalized = relative_path |> Path.split() |> Enum.join("/")

    String.starts_with?(normalized, ".beamcore/snapshots") or
      String.starts_with?(normalized, ".beamcore/recovery")
  end

  defp journal_path(workspace_root),
    do: Path.join([workspace_root, @internal_dir, @snapshot_dir, @journal_file])

  defp blob_dir(workspace_root),
    do: Path.join([workspace_root, @internal_dir, @snapshot_dir, @blob_dir])

  defp blob_path(workspace_root, hash), do: Path.join(blob_dir(workspace_root), hash)

  defp recovery_base(workspace_root, restore_id),
    do: Path.join([workspace_root, @internal_dir, @recovery_dir, restore_id])

  defp restore_intent_path(workspace_root, restore_id),
    do:
      Path.join([workspace_root, @internal_dir, @snapshot_dir, "restores", "#{restore_id}.json"])

  defp safety_revision_path(workspace_root, restore_id),
    do:
      Path.join([
        workspace_root,
        @internal_dir,
        @snapshot_dir,
        "restores",
        "#{restore_id}.safety.json"
      ])

  defp split_lines(content), do: String.split(content, "\n", trim: false)

  defp join_like(lines, original) do
    joined = Enum.join(lines, "\n")

    if String.ends_with?(original, "\n") or not String.ends_with?(joined, "\n") do
      joined
    else
      String.trim_trailing(joined, "\n")
    end
  end

  defp diff_hunk(base_lines, agent_lines) do
    prefix =
      base_lines
      |> Enum.zip(agent_lines)
      |> Enum.take_while(fn {left, right} -> left == right end)
      |> length()

    base_tail = Enum.drop(base_lines, prefix)
    agent_tail = Enum.drop(agent_lines, prefix)

    suffix =
      base_tail
      |> Enum.reverse()
      |> Enum.zip(Enum.reverse(agent_tail))
      |> Enum.take_while(fn {left, right} -> left == right end)
      |> length()

    base_mid = Enum.slice(base_lines, prefix, length(base_lines) - prefix - suffix)
    agent_mid = Enum.slice(agent_lines, prefix, length(agent_lines) - prefix - suffix)
    {prefix, base_mid, agent_mid, suffix}
  end

  defp find_unique_sublist(_lines, []), do: :ambiguous

  defp find_unique_sublist(lines, needle) do
    max_start = length(lines) - length(needle)

    matches =
      if max_start < 0 do
        []
      else
        Enum.filter(0..max_start, fn index ->
          Enum.slice(lines, index, length(needle)) == needle
        end)
      end

    case matches do
      [index] -> {:ok, index}
      [] -> :not_found
      _ -> :ambiguous
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp text_bytes?(bytes) do
    :binary.match(bytes, <<0>>) == :nomatch and String.valid?(bytes)
  end

  defp mode_bits(mode), do: Bitwise.band(mode, 0o777)

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: to_string(value)
  defp text(_), do: nil

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp integer(_value, default), do: default

  defmodule ListHelper do
    @moduledoc false

    def replace_at(lines, index, delete_count, replacement) do
      Enum.slice(lines, 0, index) ++
        replacement ++ Enum.slice(lines, index + delete_count, length(lines))
    end
  end
end
