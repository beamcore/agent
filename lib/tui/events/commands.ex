defmodule Beamcore.TUI.Events.Commands do
  @moduledoc false

  alias Beamcore.Agent.Chat.{Commands, Loop, Session}
  alias Beamcore.TUI.Events.Commands.Input, as: CmdInput
  alias Beamcore.TUI.State

  defdelegate submit(state), to: CmdInput
  defdelegate accept_command_completion(state), to: CmdInput
  defdelegate clear_input(state), to: CmdInput
  defdelegate input_blank?(state), to: CmdInput
  defdelegate select_command(state, offset), to: CmdInput
  defdelegate navigate_history(state, direction), to: CmdInput
  defdelegate refresh_commands(state), to: CmdInput

  def run_command(state, command) when command in ["quit", "exit", "q"],
    do: %{state | status: :quit}

  def run_command(%{show_help: true} = state, "help"), do: %{state | show_help: false}
  def run_command(state, "help"), do: %{state | show_help: true}

  def run_command(state, "clear"),
    do: %{state | messages: [], scroll_offset: 0} |> State.mark_dirty()

  def run_command(state, "stop") do
    if state.worker != nil do
      Process.exit(state.worker, :kill)

      state
      |> Map.put(:worker, nil)
      |> Map.update!(:session, fn
        nil -> nil
        session -> Session.interrupt(session, "Execution interrupted by user.")
      end)
      |> State.pause()
      |> State.add_message(:system, "Execution interrupted. Type a message and send to resume.")
    else
      State.add_message(
        state,
        :system,
        "Session paused. Type a message and send to resume."
      )
      |> Map.update!(:session, fn
        nil -> nil
        session -> Session.interrupt(session, "Session paused by user.")
      end)
      |> State.pause()
    end
  end

  def run_command(state, command) do
    result =
      Commands.execute(command, state.session,
        output: fn message -> send(self(), {:runtime_event, self(), {:assistant, message}}) end
      )

    apply_command_result(result, state, command)
  end

  def resume_session(state, message) do
    message = String.trim(message)
    state = State.resume(state)

    state =
      Map.update!(state, :session, fn
        nil -> nil
        session -> Session.resume_interrupted(session, "Session resumed.")
      end)

    cond do
      message != "" ->
        state
        |> State.add_message(:user, message)
        |> start_turn(message, nil)

      true ->
        state
        |> State.add_message(:system, "Session resumed.")
    end
  end

  def start_turn(state, content, caps) do
    parent = self()
    session = state.session

    {:ok, pid} =
      start_turn_worker(fn ->
        current_worker_pid = self()

        if session.workspace_root do
          Process.put(:workspace_root, session.workspace_root)
        end

        try do
          updated =
            Loop.send_message(session, content, nil, caps,
              silent: true,
              event_handler: fn event ->
                send(parent, {:runtime_event, current_worker_pid, event})
              end
            )

          send(parent, {:agent_done, self(), updated})
        rescue
          error ->
            send(parent, {:agent_error, self(), error, __STACKTRACE__})
        catch
          kind, reason ->
            send(parent, {:agent_error, self(), {kind, reason}, __STACKTRACE__})
        end
      end)

    State.start_worker(state, pid)
  end

  defp apply_command_result({:run_pending, session, content, caps}, state, _command) do
    state
    |> State.set_session(session)
    |> State.add_message(:system, "Executing legacy pending action once.")
    |> start_turn(content, caps)
  end

  defp apply_command_result(session, state, "new" <> _ = command) do
    msg =
      if String.trim(command) == "new" do
        "Started a fresh session."
      else
        "Started session (ID: #{session.session_id})."
      end

    %{
      state
      | session: session,
        messages: [],
        activity: [],
        selected_activity: 0
    }
    |> State.add_message(:system, msg)
  end

  defp apply_command_result(session, state, _command), do: State.set_session(state, session)

  defp start_turn_worker(fun) when is_function(fun, 0) do
    if Process.whereis(Beamcore.Agent.TaskSupervisor) do
      Task.Supervisor.start_child(Beamcore.Agent.TaskSupervisor, fun)
    else
      Task.start(fun)
    end
  end
end
