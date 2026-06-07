defmodule Beamcore.Agent.Runtime do
  @moduledoc """
  OTP GenServer that orchestrates the agent tool-call loop.

  Acts as a non-blocking state machine:
    :idle → :running → :idle (normal flow)
    :running → :paused → :running (pause/resume with alignment)

  All blocking work (API calls, tool execution) is delegated to async tasks.
  The GenServer only manages state transitions and checks for pause signals
  between steps.

  ## Pause/Resume

  Pause takes effect at batch boundaries — after all tool_calls from one
  assistant message are executed, but before the next LLM API call. On resume,
  the user's alignment text is injected as a user message and the loop continues.
  """

  use GenServer
  require Logger

  alias Beamcore.Agent.Chat.{API, Context, CorrectionCatch, Session, ToolPolicy}
  alias Beamcore.Agent.Tools.Dispatcher

  @max_tool_depth 100
  @event_content_limit 1_200
  @event_content_head 420
  @event_content_tail 260

  defstruct [
    :session,
    :messages,
    :depth,
    :policy,
    :tui_pid,
    :active_ref,
    :active_pid,
    :active_tool_call,
    :generation,
    :alignment_text,
    status: :idle,
    pending_tools: [],
    tool_results: []
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @doc """
  Begin a new turn. The session and content are sent to the Runtime,
  which drives the tool-call loop asynchronously.
  """
  def send_message(pid, session, content, policy) do
    GenServer.cast(pid, {:send_message, session, content, policy})
  end

  @doc """
  Pause the agent loop at the next batch boundary.
  """
  def pause(pid) do
    GenServer.cast(pid, :pause)
  end

  @doc """
  Resume a paused agent loop, injecting alignment text before the next API call.
  """
  def resume(pid, alignment_text) do
    GenServer.cast(pid, {:resume, alignment_text})
  end

  @doc """
  Hard interrupt: immediately kill any in-flight task, synthesize interrupted
  tool responses to keep the session valid, and transition to idle.
  """
  def hard_interrupt(pid) do
    GenServer.cast(pid, :hard_interrupt)
  end

  @doc """
  Returns the current status of the runtime.
  """
  def status(pid) do
    GenServer.call(pid, :status)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    tui_pid = Keyword.get(opts, :tui_pid)
    if tui_pid, do: Process.monitor(tui_pid)

    {:ok,
     %__MODULE__{
       tui_pid: tui_pid,
       generation: 0
     }}
  end

  @impl true
  def handle_cast({:send_message, session, content, policy}, state) do
    state = begin_turn(state, session, content, policy)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:pause, %{status: :running} = state) do
    {:noreply, %{state | status: :paused}}
  end

  @impl true
  def handle_cast(:pause, state), do: {:noreply, state}

  @impl true
  def handle_cast({:resume, alignment_text}, %{status: :paused} = state) do
    state = %{state | status: :running, alignment_text: alignment_text}
    send(self(), {:next_step, state.generation})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:resume, _text}, state), do: {:noreply, state}

  @impl true
  def handle_cast(:hard_interrupt, %{status: status} = state)
      when status in [:running, :paused] do
    # Kill in-flight task if present
    if state.active_ref do
      Process.demonitor(state.active_ref, [:flush])
    end

    if state.active_pid do
      Task.Supervisor.terminate_child(Beamcore.Agent.TaskSupervisor, state.active_pid)
    end

    # Synthesize "interrupted" responses for the active + pending tool calls
    # to keep message history valid for future API calls
    interrupted_tools =
      [state.active_tool_call | state.pending_tools]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn tool_call ->
        %{
          role: "tool",
          tool_call_id: tool_call["id"],
          name: tool_call["function"]["name"],
          content: "[interrupted by user]"
        }
      end)

    new_messages = state.messages ++ state.tool_results ++ interrupted_tools
    session = %{state.session | messages: Session.compact_history(new_messages)}

    # Bump generation to invalidate any stale :next_step messages
    generation = state.generation + 1

    emit(state, {:session, session})
    emit(state, {:status, :idle})

    {:noreply,
     %{
       state
       | status: :idle,
         session: session,
         messages: new_messages,
         active_ref: nil,
         active_pid: nil,
         active_tool_call: nil,
         pending_tools: [],
         tool_results: [],
         generation: generation
     }}
  end

  @impl true
  def handle_cast(:hard_interrupt, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  # --- Async task results ---

  @impl true
  def handle_info({ref, result}, %{active_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    handle_task_result(result, state)
  end

  # Stale result from a previous generation — discard
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_ref: ref} = state) do
    Logger.error("Runtime: async task crashed: #{inspect(reason)}")
    emit(state, {:error, "Internal error: #{inspect(reason)}"})
    finish_turn(state)
  end

  # TUI process went down
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{tui_pid: pid} = state)
      when pid != nil do
    {:stop, :normal, %{state | tui_pid: nil}}
  end

  # Stale DOWN
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Step driver — checks pause before proceeding
  @impl true
  def handle_info({:next_step, gen}, %{generation: gen, status: :paused} = state) do
    # Paused at batch boundary. Inject alignment if we have one and resume.
    case state.alignment_text do
      nil ->
        # Stay paused, waiting for resume
        {:noreply, state}

      text ->
        # Inject alignment and continue
        state = inject_alignment(state, text)
        schedule_api_call(state)
    end
  end

  @impl true
  def handle_info({:next_step, gen}, %{generation: gen, status: :idle} = state) do
    # Hard interrupt set us idle — ignore stale step
    {:noreply, state}
  end

  @impl true
  def handle_info({:next_step, gen}, %{generation: gen} = state) do
    schedule_api_call(state)
  end

  # Stale step message from old generation
  @impl true
  def handle_info({:next_step, _old_gen}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal Logic ---

  defp begin_turn(state, session, content, policy) do
    generation = state.generation + 1

    # Prepare session (same logic as Loop.do_send_message)
    session =
      if session.project_policy_bypassed? do
        Session.clear_project_policy_block_history(session)
      else
        session
      end

    resolved_policy =
      policy
      |> Kernel.||(session.policy_override)
      |> Kernel.||(ToolPolicy.from_user_message(content))
      |> apply_session_project_policy_bypass(session)

    emit(state, {:status, :thinking})

    session =
      if ToolPolicy.confirmation_required?(resolved_policy) do
        %{session | pending_user_message: content}
      else
        %{session | pending_user_message: nil}
      end

    context =
      if ToolPolicy.project_policy_bypassed?(resolved_policy) do
        Context.clear_policy_blocks(session.context)
      else
        session.context
      end

    session = %{session | context: Context.from_user_request(context, content, resolved_policy)}
    user_message = %{role: "user", content: content}
    Session.log(session, user_message)

    messages = session.messages ++ [user_message]

    new_state = %{
      state
      | session: session,
        messages: messages,
        depth: 0,
        policy: resolved_policy,
        status: :running,
        generation: generation,
        active_ref: nil,
        pending_tools: [],
        tool_results: [],
        alignment_text: nil
    }

    schedule_api_call(new_state)
    |> elem(1)
  end

  defp schedule_api_call(%{depth: depth} = state) when depth >= @max_tool_depth do
    emit(state, {:error, "Tool loop depth limit (#{@max_tool_depth}) reached. Stopping."})
    session = %{state.session | messages: Session.compact_history(state.messages)}
    finish_turn(%{state | session: session})
  end

  defp schedule_api_call(state) do
    # Check for hard rollover
    if Session.needs_rollover_now?(state.session) do
      rolled = Session.summarize_and_rollover(state.session, state.messages, nil)
      finish_turn(%{state | session: rolled})
    else
      spawn_api_call(state)
    end
  end

  defp spawn_api_call(state) do
    session = state.session
    messages = state.messages
    policy = state.policy
    tools = Dispatcher.tool_specs(policy)

    api_messages =
      messages
      |> Session.prepare_for_api(session.context, 24)
      |> inject_policy_message(policy, tools)

    task =
      Task.Supervisor.async_nolink(Beamcore.Agent.TaskSupervisor, fn ->
        API.execute(session.client, api_messages, tools, :main, silent: true)
      end)

    {:noreply, %{state | active_ref: task.ref, active_pid: task.pid, active_tool_call: nil}}
  end

  defp handle_task_result({:api_result, result}, state) do
    handle_api_result(result, state)
  end

  defp handle_task_result({:tool_result, tool_call, content}, state) do
    handle_tool_result(tool_call, content, state)
  end

  # Direct API result from async_nolink (the task returns the API result directly)
  defp handle_task_result({:ok, %{message: message, raw_response: raw_response}}, state) do
    handle_api_result({:ok, %{message: message, raw_response: raw_response}}, state)
  end

  defp handle_task_result({:error, _} = error, state) do
    handle_api_result(error, state)
  end

  defp handle_api_result({:ok, %{message: message, raw_response: raw_response}}, state) do
    session = state.session
    Session.log(session, Session.compact_raw_response(raw_response))

    emit(state, {:assistant, message["content"]})

    session =
      if usage = raw_response["usage"] do
        Session.update_usage(session, usage)
      else
        session
      end

    emit(state, {:session, session})

    message = normalize_tool_calls(message)
    compacted_message = Session.compact_for_api(message)
    new_messages = state.messages ++ [compacted_message]

    # Check for stuck loops
    case CorrectionCatch.stuck?(new_messages) do
      {true, reason} ->
        emit(state, {:error, "Loop detected: #{reason}"})
        rolled = CorrectionCatch.correct_and_rollover(session, new_messages, reason, nil)

        continue_prompt =
          "SYSTEM INTERRUPT: A mechanical loop was detected (#{reason}). " <>
            "The session has been compacted with a diagnosis. " <>
            "Follow the corrected plan — do NOT repeat the previous approach."

        # Start a new sub-turn with the correction prompt
        state = %{state | session: rolled, messages: rolled.messages, depth: 0}
        begin_turn_state = begin_turn(state, rolled, continue_prompt, nil)
        {:noreply, begin_turn_state}

      false ->
        if has_tool_calls?(message) do
          # Queue all tool calls for sequential execution
          tool_calls = message["tool_calls"]

          state = %{
            state
            | session: session,
              messages: new_messages,
              pending_tools: tool_calls,
              tool_results: []
          }

          execute_next_tool(state)
        else
          # Natural break — no tool calls, turn is done
          session =
            if session.needs_compaction do
              Session.summarize_and_rollover(session, new_messages, nil)
            else
              %{session | messages: Session.compact_history(new_messages)}
            end

          finish_turn(%{state | session: session, messages: new_messages})
        end
    end
  end

  defp handle_api_result({:error, %OpenaiEx.Error{kind: :rate_limit}}, state) do
    emit(state, {:error, "Rate limit exceeded, please wait and try again"})
    emit(state, {:status, :error})
    finish_turn(state)
  end

  defp handle_api_result({:error, %OpenaiEx.Error{kind: :api_timeout_error}}, state) do
    emit(state, {:error, "API request timed out"})
    emit(state, {:status, :error})
    finish_turn(state)
  end

  defp handle_api_result({:error, %OpenaiEx.Error{} = error}, state) do
    msg =
      if error.message do
        if error.body,
          do: "#{error.message} | Body: #{inspect(error.body)}",
          else: "#{error.message}"
      else
        "API error (HTTP #{error.status_code || "unknown"})"
      end

    emit(state, {:error, msg})
    emit(state, {:status, :error})
    finish_turn(state)
  end

  defp handle_api_result({:error, reason}, state) do
    emit(state, {:error, "#{inspect(reason)}"})
    emit(state, {:status, :error})
    finish_turn(state)
  end

  defp execute_next_tool(%{pending_tools: []} = state) do
    # All tools in batch executed. Append results and decide next step.
    new_messages = state.messages ++ state.tool_results
    Enum.each(state.tool_results, &Session.log(state.session, &1))

    state = %{state | messages: new_messages, tool_results: [], depth: state.depth + 1}

    # This is a batch boundary — check if paused
    if state.status == :paused do
      emit(state, {:status, :paused})
      {:noreply, state}
    else
      send(self(), {:next_step, state.generation})
      {:noreply, state}
    end
  end

  defp execute_next_tool(%{pending_tools: [tool_call | rest]} = state) do
    name = tool_call["function"]["name"]
    args = decode_tool_args(tool_call["function"]["arguments"])

    emit(state, {:tool_queued, name, args})
    emit(state, {:status, :tool_running})
    emit(state, {:tool_running, name, args})

    policy = state.policy

    task =
      Task.Supervisor.async_nolink(Beamcore.Agent.TaskSupervisor, fn ->
        content = Dispatcher.execute(name, args, policy)
        {:tool_result, tool_call, content}
      end)

    {:noreply,
     %{
       state
       | active_ref: task.ref,
         active_pid: task.pid,
         active_tool_call: tool_call,
         pending_tools: rest
     }}
  end

  defp handle_tool_result(tool_call, content, state) do
    name = tool_call["function"]["name"]
    args = decode_tool_args(tool_call["function"]["arguments"])

    event_content = compact_event_content(content)
    emit(state, {:tool_finished, name, args, event_content})

    session = update_context(state.session, name, args, content)
    emit(state, {:session, session})

    tool_response = %{
      role: "tool",
      tool_call_id: tool_call["id"],
      name: name,
      content: content
    }

    state = %{
      state
      | session: session,
        tool_results: state.tool_results ++ [tool_response],
        active_tool_call: nil
    }

    execute_next_tool(state)
  end

  defp finish_turn(state) do
    emit(state, {:session, state.session})
    emit(state, {:status, :idle})

    # Notify TUI that the turn is complete
    if state.tui_pid do
      send(state.tui_pid, {:agent_done, self(), state.session})
    end

    {:noreply,
     %{
       state
       | status: :idle,
         active_ref: nil,
         active_pid: nil,
         active_tool_call: nil,
         pending_tools: [],
         tool_results: []
     }}
  end

  defp inject_alignment(state, text) do
    alignment_message = %{role: "user", content: text}
    Session.log(state.session, alignment_message)

    %{
      state
      | messages: state.messages ++ [alignment_message],
        alignment_text: nil
    }
  end

  # --- Helpers ---

  defp emit(%{tui_pid: nil}, _event), do: :ok

  defp emit(%{tui_pid: pid}, {:assistant, content})
       when is_binary(content) and content != "" do
    send(pid, {:runtime_event, self(), {:assistant, content}})
  end

  defp emit(%{tui_pid: _pid}, {:assistant, _}), do: :ok

  defp emit(%{tui_pid: pid}, event) do
    send(pid, {:runtime_event, self(), event})
  end

  defp apply_session_project_policy_bypass(policy, %{project_policy_bypassed?: true}) do
    Map.put(policy, :project_policy_bypassed?, true)
  end

  defp apply_session_project_policy_bypass(policy, _session), do: policy

  defp normalize_tool_calls(%{"tool_calls" => tool_calls} = message) when is_list(tool_calls) do
    fixed =
      Enum.map(tool_calls, fn tc ->
        tc
        |> Map.put("type", "function")
        |> Map.delete("index")
      end)

    Map.put(message, "tool_calls", fixed)
  end

  defp normalize_tool_calls(message), do: message

  defp has_tool_calls?(%{"tool_calls" => tool_calls}) when is_list(tool_calls),
    do: tool_calls != []

  defp has_tool_calls?(_), do: false

  defp inject_policy_message(messages, policy, tools) do
    policy_message = %{
      role: "system",
      content: policy_summary(policy, tools)
    }

    case messages do
      [system, context | rest] when is_map(system) and is_map(context) ->
        [system, context, policy_message | rest]

      [system | rest] when is_map(system) ->
        [system, policy_message | rest]

      other ->
        [policy_message | other]
    end
  end

  defp policy_summary(policy, tools) do
    tool_names =
      tools
      |> Enum.map(fn tool ->
        get_in(tool, [:function, :name]) || get_in(tool, ["function", "name"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    cond do
      ToolPolicy.project_policy_bypassed?(policy) ->
        "Current turn policy: freedom. Exposed tools: #{tool_names}. Project policy is bypassed for this session. Previous project-policy block messages are obsolete; retry the requested tool action directly instead of asking to update policy. Hard runtime safety still applies."

      Map.get(policy, :mode) == :unconfirmed ->
        "Current turn policy: legacy_unconfirmed. Exposed tools: #{tool_names}. Mutation tools are unavailable in this legacy compatibility mode."

      Map.get(policy, :mode) == :restricted_write ->
        allowed_paths = Enum.join(Map.get(policy, :allowed_write_paths, []), ", ")

        "Current turn policy: restricted_write. Exposed tools: #{tool_names}. Allowed write paths: #{allowed_paths}. Do not call plan."

      Map.get(policy, :mode) == :read_only ->
        "Current turn policy: read_only. Exposed tools: #{tool_names}. Do not call mutation or network tools."

      Map.get(policy, :mode) == :invalid_policy ->
        "Current turn policy: invalid_policy. Exposed tools: #{tool_names}. Mutation tools are disabled."

      true ->
        "Current turn policy: autonomous. Exposed tools: #{tool_names}. Act directly and self-correct from tool errors."
    end
  end

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_args), do: %{}

  defp update_context(session, name, args, content),
    do: %{session | context: Context.update_from_tool(session.context, name, args, content)}

  defp compact_event_content(content) when is_binary(content) do
    if String.length(content) <= @event_content_limit do
      content
    else
      char_count = String.length(content)
      line_count = content |> String.split("\n") |> length()
      omitted = max(char_count - @event_content_head - @event_content_tail, 0)
      head = String.slice(content, 0, @event_content_head)
      tail = String.slice(content, char_count - @event_content_tail, @event_content_tail)

      "#{head}\n\n[tool output omitted: #{omitted} chars omitted from #{char_count} chars, #{line_count} lines]\n\n#{tail}"
      |> String.trim()
    end
  end

  defp compact_event_content(content), do: inspect(content)

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> nil
      name -> name
    end
  end
end
