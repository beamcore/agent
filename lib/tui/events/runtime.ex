defmodule Beamcore.TUI.Events.Runtime do
  @moduledoc """
  Handles runtime events from the agent worker and worker lifecycle.
  """

  alias Beamcore.TUI.{ErrorFormatter, State}

  def handle_event({:status, status}, state), do: State.set_status(state, status)
  def handle_event({:session, session}, state), do: State.set_session(state, session)

  def handle_event({:retry_wait, event}, state) when is_map(event) do
    state
    |> State.clear_notice()
    |> State.set_wait_status(event)
  end

  def handle_event({:retry_resumed, _event}, state), do: State.clear_wait_status(state)

  def handle_event({:assistant, content}, state),
    do: state |> State.clear_notice() |> State.add_message(:assistant, content)

  def handle_event({:thinking, content}, state) when is_binary(content) and content != "" do
    State.add_message(state, :thinking, content)
  end

  def handle_event({:thinking, _content}, state), do: state

  def handle_event({:error, content}, state),
    do:
      state
      |> State.clear_notice()
      |> State.add_message(:error, recoverable_error_text(ErrorFormatter.format(content)))

  def handle_event({:local_info, content}, state),
    do: State.set_notice(state, content)

  def handle_event({:tool_queued, name, args}, state),
    do: State.add_activity(state, name, args, :queued)

  def handle_event({:tool_running, name, args}, state),
    do: State.add_activity(State.set_status(state, :tool_running), name, args, :running)

  def handle_event({:tool_finished, name, args, result}, state) do
    state = State.update_activity(state, name, args, result)

    if name == "eeva" do
      State.refresh_memory_total(state)
    else
      state
    end
  end

  def handle_event({:eeva_preview, code}, state) do
    State.add_message(state, :eeva_preview, code)
  end

  def handle_event({:eeva_failed, message}, state) do
    handle_event(
      {:execution_stopped,
       %{
         source: :eeva,
         reason: :execution_failed,
         summary: "Eeva stopped: #{message}",
         details: %{},
         recoverable?: true
       }},
      state
    )
  end

  def handle_event({:execution_stopped, event}, state) when is_map(event) do
    summary =
      event
      |> Map.get(:summary, Map.get(event, "summary", "Execution stopped."))
      |> ErrorFormatter.format()

    args =
      event
      |> Map.take([:source, :reason, :recoverable?, :details])
      |> Map.put(:summary, summary)

    rate_limited? = Map.get(event, :reason) == :rate_limited
    recoverable? = Map.get(event, :recoverable?, Map.get(event, "recoverable?", true))
    status = if rate_limited?, do: :rate_limited, else: :error
    role = if status == :rate_limited, do: :system, else: :error

    message =
      if role == :error and recoverable?, do: recoverable_error_text(summary), else: summary

    state
    |> State.set_status(status)
    |> State.add_activity("execution_stopped", args, :error)
    |> State.add_message(role, message)
  end

  def handle_event({:model_context, metadata}, state) when is_map(metadata) do
    provider = Map.get(metadata, :provider) || Map.get(metadata, "provider") || "provider"
    model = Map.get(metadata, :model) || Map.get(metadata, "model") || "model"

    estimated =
      Map.get(metadata, :final_estimated_input_tokens) ||
        Map.get(metadata, "final_estimated_input_tokens")

    window = Map.get(metadata, :context_window) || Map.get(metadata, "context_window")
    source = Map.get(metadata, :context_source) || Map.get(metadata, "context_source") || :unknown

    summary =
      "#{provider}/#{model} context #{window || "unknown"} (#{source}) · estimated input #{estimated || "unknown"} tokens"

    State.add_activity(state, "model_context", Map.put(metadata, :summary, summary), :completed)
  end

  def handle_event({:provider_usage, usage}, state) when is_map(usage) do
    source = Map.get(usage, :source) || Map.get(usage, "source") || :unknown
    total = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens")
    summary = "Provider usage #{total || "unknown"} tokens (#{source})"

    input = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")
    output = Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens")
    provider = State.provider(state.session)

    if provider && (is_integer(input) || is_integer(output)) do
      Beamcore.TUI.Components.System.Store.record_usage(provider, input || 0, output || 0)
    end

    State.add_activity(state, "provider_usage", Map.put(usage, :summary, summary), :completed)
  end

  def handle_event({:stream_delta, delta}, state) when is_binary(delta) do
    # Detect new streaming round (first delta after idle or after previous stream_done)
    state = if Map.get(state, :stream_phase) != :active do
      state |> Map.put(:stream_phase, :active) |> Map.put(:stream_new_round, true)
    else
      state
    end

    state = State.buffer_stream_delta(state, delta)

    if Map.get(state, :stream_render_timer) == nil do
      timer = Process.send_after(self(), :flush_stream_buffer, 33)
      %{state | stream_render_timer: timer} |> State.set_status(:streaming)
    else
      state
    end
  end

  def handle_event({:stream_done, _content}, state) do
    state
    |> State.flush_stream_buffer()
    |> State.finalize_streaming_message()
    |> Map.put(:stream_render_timer, nil)
    |> Map.put(:stream_phase, :done)
  end

  def handle_event(_event, state), do: state

  def finish_worker(state, session), do: State.finish_worker(state, session)

  def fail_worker(state, error_msg) do
    message =
      error_msg
      |> ErrorFormatter.format()
      |> then(&"Agent worker crashed. #{&1}")
      |> then(
        &recoverable_error_text(&1, "Details were written to #{Beamcore.AppLog.log_path()}.")
      )

    state
    |> State.clear_wait_status()
    |> State.add_message(:error, message)
    |> Map.put(:worker, nil)
    |> Map.put(:status, :idle)
    |> Map.put(:ctrl_c_pending, false)
    |> State.mark_dirty()
  end

  defp recoverable_error_text(message, extra \\ nil) do
    [message, extra]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end
end
