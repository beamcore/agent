defmodule Beamcore.Agent.Chat.Session.TimelineOps do
  @moduledoc """
  Timeline and checkpoint operations for sessions.

  Manages timeline events, checkpoint creation, session interruption/resumption,
  rewinding, forking, branch management, and state persistence.
  """

  alias Beamcore.Agent.Chat.Session

  @doc """
  Appends an event to the session timeline and optionally saves a checkpoint.
  """
  def append_timeline(session, type, summary, attrs \\ []) when is_atom(type) do
    attrs_map = normalize_event_attrs(attrs)

    event =
      Beamcore.Agent.Timeline.event(session, %{
        type: type,
        role: Map.get(attrs_map, :role),
        title: Map.get(attrs_map, :title),
        summary: summary,
        status: Map.get(attrs_map, :status, :completed),
        reversible: Map.get(attrs_map, :reversible),
        metadata: Map.get(attrs_map, :metadata, %{})
      })

    session = %{session | timeline: (session.timeline || []) ++ [event]}
    checkpoint_attrs = Map.get(attrs_map, :checkpoint, :auto)

    session =
      if important_event?(event) and checkpoint_attrs != false do
        save_checkpoint(session, event, summary, normalize_checkpoint_attrs(checkpoint_attrs))
      else
        save_state(session)
      end

    Session.log(session, %{
      event: "timeline",
      timeline: Beamcore.Agent.Timeline.to_json_event(event)
    })
  end

  @doc """
  Creates a checkpoint in the session timeline.
  """
  def checkpoint(session, message, data \\ %{}) do
    event =
      Beamcore.Agent.Timeline.event(session, %{
        type: :checkpoint_saved,
        role: :system,
        title: "Checkpoint saved",
        summary: message,
        status: :completed,
        reversible: true,
        metadata: data
      })

    session = %{session | timeline: (session.timeline || []) ++ [event]}
    save_checkpoint(session, event, message, data)
  end

  @doc """
  Marks the session as interrupted and appends a timeline event.
  """
  def interrupt(session, reason \\ "Session interrupted.") do
    %{session | interrupted?: true}
    |> append_timeline(:interrupted, reason,
      role: :user,
      title: "Session interrupted",
      reversible: true
    )
  end

  @doc """
  Resumes an interrupted session and appends a timeline event.
  """
  def resume_interrupted(session, reason \\ "Session resumed.") do
    %{session | interrupted?: false}
    |> append_timeline(:resumed, reason,
      role: :user,
      title: "Session resumed",
      reversible: false
    )
  end

  @doc """
  Rewinds the session to a specific checkpoint.
  """
  def rewind(session, checkpoint_id) do
    with checkpoint when not is_nil(checkpoint) <-
           Beamcore.Agent.Timeline.find_checkpoint(session, checkpoint_id),
         {:ok, session} <- Beamcore.Agent.Timeline.rewind(session, checkpoint_id) do
      session = save_state(session)
      {:ok, session}
    else
      nil -> {:error, "Checkpoint '#{checkpoint_id}' was not found."}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forks the session at a specific checkpoint, creating a new branch.
  """
  def fork(session, checkpoint_id, title \\ nil) do
    with checkpoint when not is_nil(checkpoint) <-
           Beamcore.Agent.Timeline.find_checkpoint(session, checkpoint_id),
         {:ok, session} <- Beamcore.Agent.Timeline.fork(session, checkpoint_id, title) do
      session = save_state(session)
      {:ok, session}
    else
      nil -> {:error, "Checkpoint '#{checkpoint_id}' was not found."}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Abandons a branch in the session.
  """
  def abandon_branch(session, branch_id, reason \\ "Branch abandoned.") do
    session
    |> Beamcore.Agent.Timeline.abandon_branch(branch_id, reason)
    |> save_state()
  end

  @doc """
  Persists the current session state and checkpoint file to disk.
  """
  def save_state(session) do
    if session.state_file do
      Beamcore.Agent.Timeline.write_atomic!(session.state_file, Session.Serializer.snapshot(session))
    end

    if session.checkpoint_file do
      Beamcore.Agent.Timeline.write_atomic!(session.checkpoint_file, %{
        "schema_version" => Beamcore.Agent.Timeline.schema_version(),
        "session_id" => session.session_id,
        "active_checkpoint_id" => session.active_checkpoint_id,
        "branch_id" => session.branch_id,
        "branches" => Session.Serializer.stringify_branches(session.branches || %{}),
        "checkpoints" =>
          Enum.map(session.checkpoints || [], &Beamcore.Agent.Timeline.to_json_checkpoint/1)
      })
    end

    session
  end

  defp save_checkpoint(session, event, summary, attrs) do
    checkpoint = Beamcore.Agent.Timeline.checkpoint(session, event, attrs || %{})
    checkpoint_event = Beamcore.Agent.Timeline.checkpoint_event(session, checkpoint, summary)
    checkpoint_event = %{checkpoint_event | parent_event_id: event.id}

    session =
      %{
        session
        | active_checkpoint_id: checkpoint.id,
          checkpoints: session.checkpoints ++ [checkpoint],
          timeline: session.timeline ++ [checkpoint_event]
      }
      |> save_state()

    Session.log(session, %{
      event: "checkpoint",
      checkpoint: Beamcore.Agent.Timeline.to_json_checkpoint(checkpoint)
    })
  end

  defp normalize_checkpoint_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_checkpoint_attrs(_attrs), do: %{}

  defp normalize_event_attrs(attrs) when is_list(attrs), do: Enum.into(attrs, %{})

  defp normalize_event_attrs(attrs) when is_map(attrs) do
    known = [:role, :title, :status, :reversible, :metadata, :checkpoint]

    if Enum.any?(known, &Map.has_key?(attrs, &1)) do
      attrs
    else
      %{metadata: attrs}
    end
  end

  defp normalize_event_attrs(_attrs), do: %{}

  defp important_event?(%{type: type}) do
    type in [
      :model_call,
      :tool_call,
      :file_change,
      :compression,
      :decision,
      :error,
      :interrupted,
      :rewound,
      :forked,
      :resumed,
      :completed,
      :failed
    ]
  end
end
