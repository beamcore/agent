defmodule Beamcore.TUI do
  @moduledoc """
  Primary terminal UI for the agent chat.

  The local interactive TUI is started directly from the caller instead of via
  an OTP supervisor. Terminal applications must inherit the caller's group
  leader so raw mode, stdin, resize events, and cleanup all belong to the
  foreground terminal session.
  """

  use ExRatatui.App

  alias Beamcore.TUI.{
    Layout,
    MessageRouter,
    MultiScreenState,
    Shell,
    State,
    TerminalOptions,
    Trace
  }

  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.Events.KeyEvents
  alias ExRatatui.Layout.Rect

  @dialyzer {:nowarn_function, [start: 0, start: 1]}

  @splash_hold_ms 1_500
  @splash_tick_ms 80

  def start(opts \\ []) do
    old_logger_level = silence_logger()
    opts = TerminalOptions.apply(opts)

    try do
      case start_link(opts) do
        {:ok, pid} -> wait_for_termination(pid)
        other -> other
      end
    rescue
      error ->
        Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :tui_start)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :tui_start)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      restore_logger(old_logger_level)
    end
  end

  defp wait_for_termination(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        if normal_exit?(reason) do
          :ok
        else
          Beamcore.AppLog.error("TUI process stopped unexpectedly", reason: inspect(reason))
          {:error, reason}
        end
    end
  end

  defp normal_exit?(reason), do: reason in [:normal, :shutdown]

  defp silence_logger do
    level = :logger.get_primary_config() |> Map.get(:level)
    :logger.set_primary_config(:level, :none)
    level
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp restore_logger(nil), do: :ok

  defp restore_logger(level) do
    :logger.set_primary_config(:level, level)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def mount(opts) do
    init_screen_providers()

    chat_state = State.new(nil, ExRatatui.textarea_new(), Keyword.put(opts, :screen_type, :agent))
    dashboard_state = TuiSystem.new(:agent)

    now = System.monotonic_time(:millisecond)

    state = %MultiScreenState{
      active_mode: :chat,
      chat_state: chat_state,
      dashboard_state: dashboard_state,
      splash?: true,
      splash_step: 0,
      splash_started_at: now,
      started_at: now
    }

    schedule_splash_tick()
    {:ok, set_viewports(state)}
  end

  defp schedule_splash_tick, do: Process.send_after(self(), :splash_tick, @splash_tick_ms)

  defp dismiss_splash(state), do: %{state | splash?: false}

  defp set_viewports(state) do
    {w, h} = ExRatatui.terminal_size()
    set_viewports(state, w, h)
  end

  # The mode bar occupies the top row, so the chat body has one fewer row.
  defp set_viewports(state, width, height) do
    area = %Rect{x: 0, y: 0, width: width, height: max(height - 1, 1)}
    h = Layout.chat_viewport_height(area, state.chat_state.screen_type)
    %{state | chat_state: State.set_chat_viewport_height(state.chat_state, h)}
  end

  @impl true
  def render(state, frame) do
    started_us = System.monotonic_time(:microsecond)

    Trace.event(:render_start, %{
      active_mode: Map.get(state, :active_mode),
      tick_ref?: is_reference(Map.get(state, :tick_ref))
    })

    try do
      widgets = Shell.render(state, frame)

      Trace.event(:render_finish, %{
        active_mode: Map.get(state, :active_mode),
        duration_us: System.monotonic_time(:microsecond) - started_us,
        widget_count: length(widgets)
      })

      widgets
    rescue
      e -> render_error(frame, "Render error: #{Exception.message(e)}")
    catch
      k, r -> render_error(frame, "Render crash: #{inspect(k)} #{inspect(r)}")
    end
  end

  defp render_error(frame, text) do
    area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    p = %ExRatatui.Widgets.Paragraph{
      text: text,
      style: Beamcore.TUI.Theme.style(:error),
      alignment: :center,
      wrap: true
    }

    [{p, area}]
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{}, %{splash?: true} = state) do
    {:noreply, dismiss_splash(state)}
  end

  def handle_event(%ExRatatui.Event.Key{} = event, state) do
    if KeyEvents.actionable?(event) do
      event
      |> handle_actionable_event(state)
      |> maybe_schedule_tick_result()
    else
      Trace.event(:event_ignored, %{
        message_type: Trace.message_type(event),
        event: inspect(event),
        active_mode: Map.get(state, :active_mode)
      })

      {:noreply, state, render?: false}
    end
  end

  @impl true
  def handle_event(event, state) do
    event
    |> handle_actionable_event(state)
    |> maybe_schedule_tick_result()
  end

  defp handle_actionable_event(event, state) do
    Trace.event(:event_received, %{
      message_type: Trace.message_type(event),
      event: inspect(event),
      active_mode: Map.get(state, :active_mode),
      tick_ref?: is_reference(Map.get(state, :tick_ref))
    })

    try do
      result =
        case event do
          %ExRatatui.Event.Key{code: "f1"} ->
            MessageRouter.switch_or_delegate(event, state, :chat)

          %ExRatatui.Event.Key{code: "f2"} ->
            MessageRouter.switch_or_delegate(event, state, :dashboard)

          %ExRatatui.Event.Key{code: "f3"} ->
            MessageRouter.switch_or_delegate(event, state, :research)

          %ExRatatui.Event.Key{code: "f4"} ->
            MessageRouter.switch_or_delegate(event, state, :mesh)

          %ExRatatui.Event.Key{code: "?"} ->
            toggle_help(event, state)

          %ExRatatui.Event.Key{code: code} when code in ["esc", "q"] and state.show_help ->
            {:noreply, %{state | show_help: false}}

          %ExRatatui.Event.Resize{width: w, height: h} ->
            {:noreply, schedule_resize_redraw(state, w, h), render?: false}

          _ ->
            delegate_to_active(event, state)
        end

      Trace.event(:event_routed, %{
        message_type: Trace.message_type(event),
        event: inspect(event),
        result: trace_transition(state, result)
      })

      result
    rescue
      e ->
        Beamcore.AppLog.exception(:error, e, __STACKTRACE__, boundary: :tui_event)
        {:noreply, set_active_notice(state, "TUI event error. See #{Beamcore.AppLog.log_path()}")}
    catch
      k, r ->
        Beamcore.AppLog.exception(k, r, __STACKTRACE__, boundary: :tui_event)
        {:noreply, set_active_notice(state, "TUI event error. See #{Beamcore.AppLog.log_path()}")}
    end
  end

  defp trace_transition(before, {:noreply, state}),
    do: trace_transition(before, {:noreply, state, []})

  defp trace_transition(before, {:noreply, state, opts}) do
    before_text = active_input_text(before)
    after_text = active_input_text(state)

    %{
      type: :noreply,
      active_mode: Map.get(state, :active_mode),
      render?: Keyword.get(opts, :render?, true),
      dirty?: active_dirty?(state),
      tick_ref?: is_reference(Map.get(state, :tick_ref)),
      input_mutated?: before_text != after_text,
      before_input_length: input_length(before_text),
      after_input_length: input_length(after_text)
    }
  end

  defp trace_transition(_before, {:stop, _state}), do: %{type: :stop}
  defp trace_transition(_before, other), do: inspect(other)

  defp active_input_text(state) do
    case MultiScreenState.get_active(state) do
      %{textarea: textarea} when not is_nil(textarea) ->
        Beamcore.TUI.Events.TextInput.value(MultiScreenState.get_active(state))

      %{providers: %{adding?: true, form: %{field: field} = form}} ->
        Map.get(form, field)

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp input_length(text) when is_binary(text), do: String.length(text)
  defp input_length(_text), do: nil

  defp active_dirty?(state) do
    case MultiScreenState.get_active(state) do
      %{render_dirty?: dirty?} -> dirty?
      _ -> nil
    end
  end

  @impl true
  def handle_info(msg, state) do
    Trace.event(:message_received, %{
      message_type: Trace.message_type(msg),
      active_mode: Map.get(state, :active_mode),
      tick_ref?: is_reference(Map.get(state, :tick_ref))
    })

    result = route_info(msg, state)

    Trace.event(:message_routed, %{
      message_type: Trace.message_type(msg),
      result: trace_transition(state, result)
    })

    maybe_schedule_tick_result(result)
  end

  defp route_info(:splash_tick, %{splash?: true} = state) do
    elapsed = System.monotonic_time(:millisecond) - state.splash_started_at

    if elapsed >= @splash_hold_ms do
      {:noreply, dismiss_splash(state)}
    else
      schedule_splash_tick()
      {:noreply, %{state | splash_step: state.splash_step + 1}}
    end
  end

  defp route_info(:splash_tick, state), do: {:noreply, state, render?: false}

  defp route_info(:load_file_finder_cache, state) do
    parent = self()

    Task.start(fn ->
      Trace.event(:file_finder_load_start)
      files = Beamcore.TUI.FileFinder.load_files()
      Trace.event(:file_finder_load_finish, %{file_count: length(files)})
      send(parent, {:file_finder_cache, files})
    end)

    {:noreply, state, render?: false}
  end

  defp route_info({:refresh_session, screen_type}, state) do
    old = state.chat_state
    new_session = Beamcore.Agent.Chat.Session.new(nil, screen_type: screen_type)
    new_chat = %{old | session: new_session, messages: []} |> State.mark_dirty()
    {:noreply, %{state | chat_state: new_chat}}
  end

  defp route_info({:tick, ref}, %{tick_ref: ref} = state) do
    state = %{state | tick_ref: nil}

    case MessageRouter.route_tick(state) do
      {:noreply, next_state} -> {:noreply, maybe_schedule_tick(next_state)}
      {:noreply, next_state, opts} -> {:noreply, maybe_schedule_tick(next_state), opts}
      other -> other
    end
  end

  defp route_info({:tick, _ref}, state), do: {:noreply, state, render?: false}

  defp route_info({:runtime_event, pid, event}, state),
    do: MessageRouter.route_runtime_event(pid, event, state)

  defp route_info({:agent_done, pid, session}, state),
    do: MessageRouter.route_agent_done(pid, session, state)

  defp route_info({:agent_error, pid, error, st}, state),
    do: MessageRouter.route_agent_error(pid, error, st, state)

  defp route_info({:file_finder_cache, files}, state),
    do: MessageRouter.route_file_finder_cache(files, state)

  defp route_info({:system_mesh_snapshot, ref, snapshot}, state),
    do: MessageRouter.route_system_mesh_snapshot(ref, snapshot, state)

  defp route_info({:provider_saved, ref, result}, state),
    do: MessageRouter.route_provider_saved(ref, result, state)

  defp route_info({:provider_action_done, ref, action, result}, state),
    do: MessageRouter.route_provider_action_done(ref, action, result, state)

  defp route_info({:resize_redraw, ref}, %{resize_redraw_ref: ref} = state),
    do: {:noreply, %{state | resize_redraw_ref: nil}}

  defp route_info({:resize_redraw, _ref}, state), do: {:noreply, state, render?: false}

  defp route_info(_msg, state), do: {:noreply, state}

  defp delegate_to_active(event, state) do
    if MultiScreenState.get_active(state) == nil do
      {:noreply, state, render?: false}
    else
      MessageRouter.delegate_event(event, state, state.active_mode)
    end
  end

  # In chat, `?` opens help only on an empty composer; otherwise it is typed.
  # Modes without a composer toggle a shell-level help overlay.
  defp toggle_help(event, %{active_mode: :chat} = state) do
    if composer_empty?(state.chat_state) do
      {:noreply, MultiScreenState.update_active(state, &%{&1 | show_help: !&1.show_help})}
    else
      delegate_to_active(event, state)
    end
  end

  defp toggle_help(_event, state), do: {:noreply, %{state | show_help: !state.show_help}}

  defp composer_empty?(chat_state) do
    Beamcore.TUI.Events.TextInput.value(chat_state) == ""
  end

  defp mark_active_dirty(%{render_dirty?: _} = screen), do: State.mark_dirty(screen)
  defp mark_active_dirty(screen), do: screen

  defp schedule_resize_redraw(state, width, height) do
    if is_reference(state.resize_redraw_ref), do: Process.cancel_timer(state.resize_redraw_ref)

    ref = make_ref()
    Process.send_after(self(), {:resize_redraw, ref}, 16)

    state
    |> set_viewports(max(width, 1), max(height, 1))
    |> MultiScreenState.update_active(&mark_active_dirty/1)
    |> Map.put(:resize_redraw_ref, ref)
  end

  defp maybe_schedule_tick(%{tick_ref: ref} = state) when is_reference(ref), do: state

  defp maybe_schedule_tick(state) do
    if tick_needed?(state) do
      ref = make_ref()
      Process.send_after(self(), {:tick, ref}, 100)
      %{state | tick_ref: ref}
    else
      state
    end
  end

  defp tick_needed?(%{active_mode: :dashboard}), do: true

  defp tick_needed?(state), do: MessageRouter.animating?(state.chat_state)

  defp maybe_schedule_tick_result({:noreply, state}),
    do: {:noreply, maybe_schedule_tick(state)}

  defp maybe_schedule_tick_result({:noreply, state, opts}),
    do: {:noreply, maybe_schedule_tick(state), opts}

  defp maybe_schedule_tick_result(other), do: other

  defp set_active_notice(state, text) do
    MultiScreenState.update_active(state, fn
      %{render_dirty?: _} = screen -> State.set_notice(screen, text)
      screen -> screen
    end)
  end

  defp init_screen_providers do
    case Beamcore.Config.active_provider() do
      nil ->
        :ok

      global ->
        for screen <- [:agent, :chat],
            Beamcore.Config.get(:"active_provider_#{screen}") == nil,
            do: Beamcore.Config.set_active_provider(screen, global)
    end
  end

  @impl true
  def terminate(_reason, state) do
    print_goodbye(state)
    :ok
  end

  defp print_goodbye(state) do
    sessions = collect_sessions(state)
    total_tokens = Enum.reduce(sessions, 0, fn s, acc -> acc + (s.total_tokens || 0) end)
    session_name = active_session_name(state)
    message_count = count_messages(state)
    duration = format_duration(state.started_at)

    IO.puts("")
    IO.puts("Session: #{session_name}")
    IO.puts("Duration: #{duration}")
    IO.puts("Messages: #{message_count}")
    IO.puts("Tokens spent: #{total_tokens}")
    IO.puts("See you later.")
  end

  defp collect_sessions(state) do
    [state.chat_state]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn s -> s.session end)
    |> Enum.reject(&is_nil/1)
  end

  defp count_messages(state) do
    [state.chat_state]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(0, fn s, acc -> acc + length(s.messages || []) end)
  end

  defp active_session_name(state) do
    case state.chat_state do
      %{session: %{session_id: id}} when is_binary(id) -> id
      _ -> "unknown"
    end
  end

  defp format_duration(nil), do: "unknown"

  defp format_duration(started_at) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    total_seconds = div(elapsed_ms, 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{seconds}s"
      minutes > 0 -> "#{minutes}m #{seconds}s"
      true -> "#{seconds}s"
    end
  end
end
