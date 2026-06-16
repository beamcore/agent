defmodule Beamcore.TUI.Events do
  @moduledoc """
  Event handling for the primary TUI.
  """

  alias Beamcore.Agent.Chat.{Commands, Loop, Session}
  alias Beamcore.TUI.{ErrorFormatter, FileFinder, History, State}
  alias ExRatatui.Event
  alias ExRatatui.Widgets.SlashCommands
  alias ExRatatui.Widgets.SlashCommands.Command

  @commands [
    %Command{name: "help", description: "Show commands and keybindings"},
    %Command{name: "env", description: "Print full env variables"},
    %Command{name: "login", description: "Configure your default API key"},
    %Command{name: "logout", description: "Clear stored default login"},
    %Command{name: "api list", description: "List all configured API providers"},
    %Command{name: "api use ", description: "Switch active API provider"},
    %Command{name: "api add ", description: "Add or update an API provider"},
    %Command{name: "api delete ", description: "Delete an API provider configuration"},
    %Command{name: "clear", description: "Clear visible chat messages"},
    %Command{name: "compress", description: "Compress/rollover the session context"},
    %Command{name: "new", description: "Start a fresh session"},
    %Command{name: "context", description: "Show compact session context"},
    %Command{name: "context clear", description: "Clear compact session context"},
    %Command{name: "stop", description: "Pause the session; type a message to resume"},
    %Command{name: "quit", description: "Exit"},
    %Command{name: "exit", description: "Exit"},
    %Command{name: "q", description: "Exit"}
  ]

  def commands, do: @commands

  def handle_event(event, state, opts \\ [])

  def handle_event(%Event.Key{} = event, state, opts) do
    code = event.code
    mods = event.modifiers

    if key_press?(event) do
      state = maybe_disarm_ctrl_c(code, mods, state)

      if code == "enter" and Keyword.get(opts, :paste, false) do
        {:noreply, insert_newline(state)}
      else
        handle_key(code, mods, state)
      end
    else
      {:noreply, state}
    end
  end

  def handle_event(%Event.Resize{}, state, _opts), do: {:noreply, State.mark_dirty(state)}

  def handle_event(%Event.Mouse{} = event, state, _opts) do
    case event.kind do
      "scroll_up" ->
        {:noreply, State.scroll_up(state, 3)}

      "scroll_down" ->
        {:noreply, State.scroll_down(state, 3)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_event(event, state, _opts) when is_map(event) do
    if paste_event?(event) do
      content =
        Map.get(event, :content) || Map.get(event, "content") || Map.get(event, :text) || ""

      insert_textarea_content(state.textarea, content)

      state = %{state | history_index: nil}
      state = handle_file_finder_key(nil, [], state)

      {:noreply, refresh_commands(state)}
    else
      {:noreply, state}
    end
  end

  def handle_event(_event, state, _opts), do: {:noreply, state}

  defp paste_event?(event) when is_map(event) do
    # Some ex_ratatui releases deliver bracketed paste as a Paste-shaped event,
    # while the locked 0.10.0 dependency does not define the struct yet. Match
    # the event shape without expanding a missing struct at compile time.
    struct_name =
      event
      |> Map.get(:__struct__)
      |> case do
        nil -> ""
        module -> Atom.to_string(module)
      end

    has_content? =
      is_binary(Map.get(event, :content)) or is_binary(Map.get(event, "content")) or
        is_binary(Map.get(event, :text))

    has_content? and
      (String.ends_with?(struct_name, ".Paste") or
         Map.get(event, :type) in [:paste, "paste"] or
         Map.get(event, "type") in [:paste, "paste"])
  end

  def handle_runtime_event({:status, status}, state), do: State.set_status(state, status)
  def handle_runtime_event({:session, session}, state), do: State.set_session(state, session)

  def handle_runtime_event({:retry_wait, event}, state) when is_map(event) do
    state
    |> State.clear_notice()
    |> State.set_wait_status(event)
  end

  def handle_runtime_event({:retry_resumed, _event}, state), do: State.clear_wait_status(state)

  def handle_runtime_event({:assistant, content}, state),
    do: state |> State.clear_notice() |> State.add_message(:assistant, content)

  def handle_runtime_event({:thinking, _content}, state), do: state

  def handle_runtime_event({:error, content}, state),
    do:
      state
      |> State.clear_notice()
      |> State.add_message(:error, recoverable_error_text(ErrorFormatter.format(content)))

  # Helper progress is transient status, not chat history. Keeping it out of the
  # transcript prevents nested provider errors and inspected terms from flooding
  # the TUI.
  def handle_runtime_event({:local_info, content}, state),
    do: State.set_notice(state, content)

  def handle_runtime_event({:tool_queued, name, args}, state),
    do: State.add_activity(state, name, args, :queued)

  def handle_runtime_event({:tool_running, name, args}, state),
    do: State.add_activity(State.set_status(state, :tool_running), name, args, :running)

  def handle_runtime_event({:tool_finished, name, args, result}, state) do
    state = State.update_activity(state, name, args, result)

    if name == "eeva" do
      State.refresh_memory_total(state)
    else
      state
    end
  end

  def handle_runtime_event({:eeva_preview, code}, state) do
    State.add_message(state, :eeva_preview, "```elixir\n#{code}\n```")
  end

  def handle_runtime_event({:eeva_failed, message}, state) do
    handle_runtime_event(
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

  def handle_runtime_event({:execution_stopped, event}, state) when is_map(event) do
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

  def handle_runtime_event({:model_context, metadata}, state) when is_map(metadata) do
    provider = Map.get(metadata, :provider) || Map.get(metadata, "provider") || "provider"
    model = Map.get(metadata, :model) || Map.get(metadata, "model") || "model"

    estimated =
      Map.get(metadata, :final_estimated_input_tokens) ||
        Map.get(metadata, "final_estimated_input_tokens")

    window = Map.get(metadata, :context_window) || Map.get(metadata, "context_window")
    source = Map.get(metadata, :context_source) || Map.get(metadata, "context_source") || :unknown

    summary =
      "#{provider}/#{model} context #{window || "unknown"} (#{source}) · estimated input #{estimated || "unknown"} tokens"

    state
    |> append_timeline_event(:model_context, summary, metadata, "Model context budget")
    |> State.add_activity("model_context", Map.put(metadata, :summary, summary), :completed)
  end

  def handle_runtime_event({:provider_usage, usage}, state) when is_map(usage) do
    source = Map.get(usage, :source) || Map.get(usage, "source") || :unknown
    total = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens")
    summary = "Provider usage #{total || "unknown"} tokens (#{source})"

    state
    |> append_timeline_event(:provider_usage, summary, usage, "Provider usage")
    |> State.add_activity("provider_usage", Map.put(usage, :summary, summary), :completed)
  end

  def handle_runtime_event(_event, state), do: state

  def handle_restore_progress(event, state) do
    status = if event.status == "failed", do: :failed, else: :completed

    session =
      Session.append_timeline(state.session, :restore_stage, event.summary,
        role: :system,
        title: event.summary,
        status: status,
        reversible: false,
        metadata: event
      )

    state
    |> State.set_session(session)
    |> State.set_status(:restoring)
  end

  def handle_restore_completed(action, checkpoint_id, {:ok, session, filesystem_result}, state) do
    session = merge_restore_progress_events(state.session, session, filesystem_result)
    label = if action == :fork, do: "Forked from", else: "Rewound to"

    state
    |> interrupt_worker()
    |> State.set_session(session)
    |> State.select_checkpoint(checkpoint_id)
    |> State.set_status(:idle)
    |> State.add_message(:system, "#{label} checkpoint #{checkpoint_id}.")
  end

  def handle_restore_completed(_action, _checkpoint_id, {:error, reason}, state) do
    state
    |> State.set_status(:idle)
    |> State.add_message(:system, ErrorFormatter.format(reason))
  end

  def handle_restore_completed(action, checkpoint_id, {:error, _session_id, reason}, state) do
    handle_restore_completed(action, checkpoint_id, {:error, reason}, state)
  end

  defp append_timeline_event(%{session: nil} = state, _type, _summary, _metadata, _title),
    do: state

  defp append_timeline_event(%{session: session} = state, type, summary, metadata, title) do
    session =
      Session.append_timeline(session, type, summary,
        role: :system,
        title: title,
        metadata: metadata,
        checkpoint: false
      )

    State.set_session(state, session)
  end

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

  defp handle_key("c", mods, state) do
    if ctrl?(mods), do: handle_ctrl_c(state), else: handle_text_key("c", mods, state)
  end

  defp handle_key(code, _mods, %{show_help: true} = state)
       when code in ["esc", "escape", "q", "space", "h", "?", "f1"] do
    {:noreply, close_panels(state)}
  end

  defp handle_key("s", mods, state) do
    if ctrl?(mods), do: {:noreply, submit(state)}, else: handle_text_key("s", mods, state)
  end

  defp handle_key("a", mods, state) do
    handle_text_key("a", mods, state)
  end

  defp handle_key(code, mods, %{file_finder_active?: true} = state) do
    cond do
      code == "up" && not ctrl?(mods) && not alt?(mods) && not shift?(mods) ->
        {:noreply, State.select_file_finder_result(state, -1)}

      code == "down" && not ctrl?(mods) && not alt?(mods) && not shift?(mods) ->
        {:noreply, State.select_file_finder_result(state, 1)}

      code == "p" && ctrl?(mods) ->
        {:noreply, State.select_file_finder_result(state, -1)}

      code == "n" && ctrl?(mods) ->
        {:noreply, State.select_file_finder_result(state, 1)}

      code == "enter" ->
        {:noreply, accept_file_finder_selection(state)}

      code in ["esc", "escape"] ->
        {:noreply, State.deactivate_file_finder(state) |> State.mark_dirty()}

      code == "tab" ->
        {:noreply, accept_file_finder_selection(state)}

      true ->
        handle_text_key(code, mods, state)
    end
  end

  defp handle_key("j", mods, state) do
    cond do
      ctrl?(mods) ->
        {:noreply, insert_newline(state)}

      true ->
        handle_text_key("j", mods, state)
    end
  end

  defp handle_key("enter", mods, state) do
    cond do
      ctrl?(mods) ->
        {:noreply, submit(state)}

      shift?(mods) or alt?(mods) ->
        {:noreply, insert_newline(state)}

      true ->
        {:noreply, insert_newline(state)}
    end
  end

  defp handle_key(code, _mods, state) when code in ["esc", "escape"] do
    state =
      state
      |> Map.put(:show_commands, false)
      |> Map.put(:command_matches, [])
      |> Map.put(:history_index, nil)

    {:noreply, state |> close_panels() |> State.mark_dirty()}
  end

  defp handle_key("tab", _mods, %{show_commands: true} = state),
    do: {:noreply, accept_command_completion(state)}

  defp handle_key("tab", _mods, state), do: handle_text_key("tab", [], state)

  defp handle_key("p", mods, state) do
    if ctrl?(mods) do
      cond do
        state.show_commands ->
          {:noreply, %{state | command_selected: max(0, state.command_selected - 1)}}

        true ->
          {:noreply, navigate_history(state, :up)}
      end
    else
      handle_text_key("p", mods, state)
    end
  end

  defp handle_key("n", mods, state) do
    if ctrl?(mods) do
      cond do
        state.show_commands ->
          max_index = max(length(state.command_matches) - 1, 0)
          {:noreply, %{state | command_selected: min(state.command_selected + 1, max_index)}}

        true ->
          {:noreply, navigate_history(state, :down)}
      end
    else
      handle_text_key("n", mods, state)
    end
  end

  defp handle_key("up", mods, state) do
    cond do
      state.show_commands ->
        {:noreply, select_command(state, -1)}

      not input_blank?(state) ->
        handle_text_key("up", mods, state)

      true ->
        {:noreply, State.scroll_up(state)}
    end
  end

  defp handle_key("down", mods, state) do
    cond do
      state.show_commands ->
        {:noreply, select_command(state, 1)}

      not input_blank?(state) ->
        handle_text_key("down", mods, state)

      true ->
        {:noreply, State.scroll_down(state)}
    end
  end

  defp handle_key(code, _mods, state)
       when code in ["page_up", "pageup", "pgup"] do
    {:noreply, State.chat_page(state, :up)}
  end

  defp handle_key(code, _mods, state)
       when code in ["page_down", "pagedown", "pgdown"] do
    {:noreply, State.chat_page(state, :down)}
  end

  defp handle_key("o", mods, state) do
    handle_text_key("o", mods, state)
  end

  defp handle_key(code, mods, state), do: handle_text_key(code, mods, state)

  defp insert_textarea_content(textarea, content) do
    value = ExRatatui.textarea_get_value(textarea)
    {row, col} = ExRatatui.textarea_cursor(textarea)
    insert_at = pos_to_char_index(value, row, col)

    new_value =
      String.slice(value, 0, insert_at) <>
        content <>
        String.slice(value, insert_at..-1//1)

    ExRatatui.textarea_set_value(textarea, new_value)

    {target_row, target_col} = char_index_to_pos(new_value, insert_at + String.length(content))
    move_textarea_cursor(textarea, target_row, target_col)
  end

  defp move_textarea_cursor(textarea, target_row, target_col) do
    # textarea_set_value/2 rebuilds the Rust TextArea and resets the cursor to
    # the beginning, so move from {0, 0} to the desired post-paste location.
    if target_row > 0 do
      Enum.each(1..target_row, fn _ -> ExRatatui.textarea_handle_key(textarea, "down") end)
    end

    if target_col > 0 do
      Enum.each(1..target_col, fn _ -> ExRatatui.textarea_handle_key(textarea, "right") end)
    end

    :ok
  end

  defp pos_to_char_index(value, row, col) do
    value
    |> String.split("\n", trim: false)
    |> Enum.take(row + 1)
    |> case do
      [] ->
        0

      lines ->
        previous = lines |> Enum.take(row) |> Enum.map(&(String.length(&1) + 1)) |> Enum.sum()
        current = lines |> List.last() |> String.slice(0, col) |> String.length()
        previous + current
    end
  end

  defp handle_text_key(code, mods, state) do
    ExRatatui.textarea_handle_key(state.textarea, code, mods)
    state = %{state | history_index: nil}

    # Check if this key press should trigger or update file finder
    state = handle_file_finder_key(code, mods, state)

    {:noreply, refresh_commands(state)}
  end

  defp handle_file_finder_key(_code, _mods, state) do
    value = ExRatatui.textarea_get_value(state.textarea)
    cursor_pos = ExRatatui.textarea_cursor(state.textarea)

    case FileFinder.parse(value, cursor_pos) do
      {:file_query, query, _start, _end} ->
        # Load files and update file finder state
        cache = state.file_finder_cache || FileFinder.load_files()
        results = FileFinder.search(query, cache)

        state =
          if state.file_finder_active? do
            State.update_file_finder_query(state, query, results)
          else
            State.activate_file_finder(state, query, results)
          end

        state |> Map.put(:file_finder_cache, cache)

      :no_file_query ->
        # Deactivate file finder if @ is not present
        if state.file_finder_active? do
          State.deactivate_file_finder(state)
        else
          state
        end
    end
  end

  defp accept_file_finder_selection(state) do
    case Enum.at(state.file_finder_results, state.file_finder_selected) do
      nil ->
        state

      file_path ->
        value = ExRatatui.textarea_get_value(state.textarea)
        cursor_pos = ExRatatui.textarea_cursor(state.textarea)

        case FileFinder.parse(value, cursor_pos) do
          {:file_query, _query, start, end_pos} ->
            # Replace the @query with the selected file path without brackets
            replacement = "@" <> file_path <> " "

            new_value =
              String.slice(value, 0, start) <>
                replacement <>
                String.slice(value, end_pos..-1//1)

            ExRatatui.textarea_set_value(state.textarea, new_value)

            # Reposition the cursor right after the inserted file path
            {target_row, target_col} =
              char_index_to_pos(new_value, start + String.length(replacement))

            if target_row > 0,
              do:
                Enum.each(1..target_row, fn _ ->
                  ExRatatui.textarea_handle_key(state.textarea, "down")
                end)

            if target_col > 0,
              do:
                Enum.each(1..target_col, fn _ ->
                  ExRatatui.textarea_handle_key(state.textarea, "right")
                end)

            State.deactivate_file_finder(state)

          :no_file_query ->
            state
        end
    end
  end

  defp char_index_to_pos(string, index) do
    sub_str = String.slice(string, 0, index)
    lines = String.split(sub_str, "\n", trim: false)
    row = length(lines) - 1
    col = String.length(List.last(lines))
    {row, col}
  end

  defp navigate_history(state, :up) do
    case state.history do
      [] ->
        state

      history ->
        case state.history_index do
          nil ->
            draft = ExRatatui.textarea_get_value(state.textarea)
            index = length(history) - 1
            value = Enum.at(history, index)
            ExRatatui.textarea_set_value(state.textarea, value)
            %{state | history_index: index, history_draft: draft} |> State.mark_dirty()

          index ->
            new_index = max(0, index - 1)
            value = Enum.at(history, new_index)
            ExRatatui.textarea_set_value(state.textarea, value)
            %{state | history_index: new_index} |> State.mark_dirty()
        end
    end
  end

  defp navigate_history(state, :down) do
    case state.history_index do
      nil ->
        state

      index ->
        history = state.history
        new_index = index + 1

        if new_index >= length(history) do
          ExRatatui.textarea_set_value(state.textarea, state.history_draft)
          %{state | history_index: nil} |> State.mark_dirty()
        else
          value = Enum.at(history, new_index)
          ExRatatui.textarea_set_value(state.textarea, value)
          %{state | history_index: new_index} |> State.mark_dirty()
        end
    end
  end

  defp ctrl?(nil), do: false
  defp ctrl?(mods), do: "ctrl" in mods

  # Multi-purpose Ctrl+C: the first press arms a context-aware action and the
  # second matching press confirms it. While a turn is running it pauses the
  # session; while idle (or paused) it exits the app. Switching context between
  # presses re-arms with the new action instead of confirming the old one.
  defp handle_ctrl_c(state) do
    if input_blank?(state) do
      desired = if worker_running?(state), do: :pause, else: :exit

      if state.ctrl_c_pending == desired do
        confirm_ctrl_c(desired, State.disarm_ctrl_c(state))
      else
        {:noreply, State.arm_ctrl_c(state, desired)}
      end
    else
      # First Ctrl+C clears a non-empty composer (shell-style). Once the input
      # is empty, a subsequent Ctrl+C arms pause/exit via the branch above.
      {:noreply, clear_input(state)}
    end
  end

  defp clear_input(state) do
    ExRatatui.textarea_set_value(state.textarea, "")

    %{state | history_index: nil, file_finder_active?: false, file_finder_results: []}
    |> State.disarm_ctrl_c()
    |> refresh_commands()
  end

  defp confirm_ctrl_c(:pause, state), do: {:noreply, run_command(state, "stop")}
  defp confirm_ctrl_c(:exit, state), do: {:stop, state}

  defp worker_running?(%{worker: worker}), do: not is_nil(worker)

  defp session_paused?(%{session: %{session_paused: true}}), do: true
  defp session_paused?(_state), do: false

  defp maybe_disarm_ctrl_c("c", mods, state) do
    if ctrl?(mods), do: state, else: State.disarm_ctrl_c(state)
  end

  defp maybe_disarm_ctrl_c(_code, _mods, state), do: State.disarm_ctrl_c(state)

  defp alt?(nil), do: false
  defp alt?(mods), do: "alt" in mods

  defp shift?(nil), do: false
  defp shift?(mods), do: "shift" in mods

  defp insert_newline(state) do
    ExRatatui.textarea_handle_key(state.textarea, "enter", [])

    state
    |> Map.put(:history_index, nil)
    |> State.mark_dirty()
  end

  defp submit(%{worker: worker} = state) when not is_nil(worker) do
    value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

    if value == "/stop" do
      ExRatatui.textarea_set_value(state.textarea, "")
      run_command(%{state | show_commands: false}, "stop")
    else
      # Keep the text in the composer so the user doesn't lose their input.
      # They can edit and resubmit once the worker finishes or is stopped.
      State.add_message(
        state,
        :system,
        "Agent is still working. Press Ctrl+C to stop, or wait for it to finish."
      )
    end
  end

  defp submit(state) do
    if State.paused?(state) do
      value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

      cond do
        value == "" ->
          state

        String.starts_with?(value, "/") ->
          ExRatatui.textarea_set_value(state.textarea, "")
          state = maybe_record_command_history(state, value)
          run_command(%{state | show_commands: false}, String.trim_leading(value, "/"))

        true ->
          # A plain message while paused resumes the session with the typed text
          # so users can send again after a Ctrl+C pause.
          ExRatatui.textarea_set_value(state.textarea, "")
          state = record_history(state, value)
          resume_session(%{state | show_commands: false}, value)
      end
    else
      value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

      cond do
        value == "" ->
          state

        String.starts_with?(value, "/") ->
          ExRatatui.textarea_set_value(state.textarea, "")
          state = maybe_record_command_history(state, value)
          run_command(%{state | show_commands: false}, String.trim_leading(value, "/"))

        session_paused?(state) ->
          State.add_message(
            state,
            :system,
            "Session paused: context exceeds 200k tokens. Run /compress to compress the session."
          )

        true ->
          ExRatatui.textarea_set_value(state.textarea, "")
          state = record_history(state, value)

          state
          |> State.add_message(:user, value)
          |> start_turn(value, nil)
          |> Map.put(:show_commands, false)
      end
    end
  end

  defp accept_command_completion(state) do
    case Enum.at(state.command_matches, state.command_selected) do
      nil ->
        state

      %Command{name: name} ->
        ExRatatui.textarea_set_value(state.textarea, "/" <> name)

        %{state | show_commands: false, command_matches: [], command_selected: 0}
        |> State.mark_dirty()
    end
  end

  defp input_blank?(state) do
    state.textarea
    |> ExRatatui.textarea_get_value()
    |> String.trim()
    |> Kernel.==("")
  end

  defp select_command(state, offset) do
    max_index = max(length(state.command_matches) - 1, 0)
    selected = state.command_selected + offset

    %{state | command_selected: selected |> max(0) |> min(max_index)}
    |> State.mark_dirty()
  end

  defp record_history(state, value) do
    value = String.trim(value)

    if value != "" do
      last_entry = List.last(state.history)

      if value != last_entry do
        History.append(value)
        %{state | history: state.history ++ [value], history_index: nil}
      else
        %{state | history_index: nil}
      end
    else
      %{state | history_index: nil}
    end
  end

  defp maybe_record_command_history(state, "/login" <> _suffix), do: %{state | history_index: nil}
  defp maybe_record_command_history(state, value), do: record_history(state, value)

  defp run_command(state, command) when command in ["quit", "exit", "q"],
    do: %{state | status: :quit}

  defp run_command(%{show_help: true} = state, "help"), do: %{state | show_help: false}
  defp run_command(state, "help"), do: %{state | show_help: true}

  defp run_command(state, "clear"),
    do: %{state | messages: [], scroll_offset: 0} |> State.mark_dirty()

  defp run_command(state, "stop") do
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

  defp run_command(state, command) do
    result =
      Commands.execute(command, state.session,
        output: fn message -> send(self(), {:runtime_event, self(), {:assistant, message}}) end
      )

    apply_command_result(result, state, command)
  end

  defp resume_session(state, message) do
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

  defp merge_restore_progress_events(current_session, restored_session, filesystem_result) do
    restore_id = filesystem_result["recovery_id"]

    progress_events =
      current_session.timeline
      |> Enum.filter(fn event ->
        event.type == :restore_stage and
          is_map(event.metadata) and
          event.metadata.restore_id == restore_id
      end)

    if progress_events == [] do
      restored_session
    else
      existing_ids = MapSet.new(Enum.map(restored_session.timeline || [], & &1.id))
      new_events = Enum.reject(progress_events, &MapSet.member?(existing_ids, &1.id))
      %{restored_session | timeline: (restored_session.timeline || []) ++ new_events}
    end
  end

  defp interrupt_worker(%{worker: nil} = state), do: state

  defp interrupt_worker(state) do
    Process.exit(state.worker, :kill)
    %{state | worker: nil, status: :paused}
  end

  defp apply_command_result({:run_pending, session, content, caps}, state, _command) do
    state
    |> State.set_session(session)
    |> State.add_message(
      :system,
      "Executing legacy pending action once."
    )
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
        selected_activity: 0,
        activity_scroll_offset: 0
    }
    |> State.add_message(:system, msg)
  end

  defp apply_command_result(session, state, _command), do: State.set_session(state, session)

  defp start_turn(state, content, caps) do
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

  defp start_turn_worker(fun) when is_function(fun, 0) do
    if Process.whereis(Beamcore.Agent.TaskSupervisor) do
      Task.Supervisor.start_child(Beamcore.Agent.TaskSupervisor, fun)
    else
      Task.start(fun)
    end
  end

  defp refresh_commands(state) do
    value = ExRatatui.textarea_get_value(state.textarea)

    case SlashCommands.parse(value) do
      {:command, prefix} ->
        matches = SlashCommands.match_commands(@commands, prefix)

        %{state | show_commands: matches != [], command_matches: matches, command_selected: 0}
        |> State.mark_dirty()

      :no_command ->
        %{state | show_commands: false, command_matches: []}
        |> State.mark_dirty()
    end
  end

  defp close_panels(state) do
    state
    |> Map.put(:show_help, false)
    |> Map.put(:show_commands, false)
    |> Map.put(:show_activity_details, false)
  end

  defp key_press?(%{kind: kind}), do: kind in [nil, "press", :press]
end
