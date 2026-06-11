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
    %Command{name: "api select", description: "Open interactive provider selector"},
    %Command{name: "api use ", description: "Switch active API provider"},
    %Command{name: "api add ", description: "Add or update an API provider"},
    %Command{name: "api delete ", description: "Delete an API provider configuration"},
    %Command{name: "providers", description: "Open interactive provider selector"},
    %Command{name: "helper status", description: "Show optional helper selection"},
    %Command{name: "helper list", description: "List helper-capable providers"},
    %Command{name: "helper models ", description: "List models from a local provider"},
    %Command{name: "helper use ", description: "Choose helper provider and model"},
    %Command{name: "helper off", description: "Disable optional helper model"},
    %Command{name: "new", description: "Start a fresh session"},
    %Command{name: "context", description: "Show compact session context"},
    %Command{name: "context clear", description: "Clear compact session context"},
    %Command{name: "policy", description: "Show project policy summary"},
    %Command{name: "policy show", description: "Show normalized project policy config"},
    %Command{name: "policy init", description: "Create the local policy config"},
    %Command{name: "policy reload", description: "Reload project policy"},
    %Command{name: "policy deny path ", description: "Add a denied path pattern"},
    %Command{name: "policy allow-write ", description: "Add an allowed write path"},
    %Command{name: "policy read-only ", description: "Add a read-only path"},
    %Command{name: "policy tool ", description: "Set tool permission"},
    %Command{name: "timeline", description: "Focus timeline details"},
    %Command{name: "timeline last", description: "Open latest timeline item"},
    %Command{name: "timeline clear", description: "Clear visible UI activity only"},
    %Command{name: "checkpoint rewind ", description: "Rewind to a checkpoint"},
    %Command{name: "checkpoint fork ", description: "Fork from a checkpoint"},
    %Command{name: "checkpoint abandon ", description: "Mark a branch abandoned"},
    %Command{name: "yolo", description: "Toggle freedom mode"},
    %Command{name: "yolo on", description: "Bypass project policy for this session"},
    %Command{name: "yolo off", description: "Restore project policy for this session"},
    %Command{name: "stop", description: "Pause the session to add improved direction"},
    %Command{
      name: "continue",
      description: "Resume the paused research session, optional alignment"
    },
    %Command{name: "resume", description: "Alias for continue"},
    %Command{
      name: "drop",
      description: "Discard/delete the current research session and restart fresh"
    },
    %Command{
      name: "kick",
      description: "Force trigger next turn in research session immediately"
    },
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

  def handle_event(%Event.Mouse{} = event, state, opts) do
    {width, height} =
      case Keyword.fetch(opts, :terminal_size) do
        {:ok, size} -> size
        :error -> ExRatatui.terminal_size()
      end

    areas =
      Beamcore.TUI.Layout.areas(%ExRatatui.Layout.Rect{
        x: 0,
        y: 0,
        width: width,
        height: height
      })

    in_activity? =
      case areas do
        %{activity: %ExRatatui.Layout.Rect{} = rect} ->
          event.x >= rect.x and event.x < rect.x + rect.width and
            event.y >= rect.y and event.y < rect.y + rect.height

        _ ->
          false
      end

    case event.kind do
      "scroll_up" ->
        if in_activity? do
          {:noreply, scroll_activity(state, :up)}
        else
          {:noreply, State.scroll_up(state, 3)}
        end

      "scroll_down" ->
        if in_activity? do
          {:noreply, scroll_activity(state, :down)}
        else
          {:noreply, State.scroll_down(state, 3)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_event(_event, state, _opts), do: {:noreply, state}

  def handle_runtime_event({:status, status}, state), do: State.set_status(state, status)
  def handle_runtime_event({:session, session}, state), do: State.set_session(state, session)

  def handle_runtime_event({:assistant, content}, state),
    do: state |> State.clear_notice() |> State.add_message(:assistant, content)

  def handle_runtime_event({:thinking, content}, state),
    do: state |> State.add_message(:thinking, content)

  def handle_runtime_event({:error, content}, state),
    do: state |> State.clear_notice() |> State.add_message(:error, ErrorFormatter.format(content))

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
    State.add_message(state, :error, "⚡ EEVA failed: #{message}")
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

  def finish_worker(state, session), do: State.finish_worker(state, session)

  def fail_worker(state, error_msg) do
    state
    |> State.add_message(:system, "Agent crashed: #{error_msg}")
    |> Map.put(:worker, nil)
    |> Map.put(:status, :idle)
    |> State.mark_dirty()
  end

  defp handle_key("c", mods, state) do
    if ctrl?(mods), do: {:stop, state}, else: handle_text_key("c", mods, state)
  end

  defp handle_key(code, _mods, %{show_help: true} = state)
       when code in ["esc", "escape", "q", "space", "h", "?", "f1"] do
    {:noreply, close_panels(state)}
  end

  defp handle_key("s", mods, state) do
    if ctrl?(mods), do: {:noreply, submit(state)}, else: handle_text_key("s", mods, state)
  end

  defp handle_key("f6", _mods, state), do: {:noreply, State.focus_activity(state)}

  defp handle_key("a", mods, state) do
    cond do
      ctrl?(mods) and state.show_activity_details ->
        {:noreply, abandon_selected_branch(state)}

      ctrl?(mods) ->
        handle_text_key("a", mods, state)

      true ->
        handle_text_key("a", mods, state)
    end
  end

  defp handle_key(code, mods, %{provider_selector_active?: true} = state) do
    cond do
      code == "up" && not ctrl?(mods) && not alt?(mods) && not shift?(mods) ->
        {:noreply, State.select_provider_selector_result(state, -1)}

      code == "down" && not ctrl?(mods) && not alt?(mods) && not shift?(mods) ->
        {:noreply, State.select_provider_selector_result(state, 1)}

      code == "p" && ctrl?(mods) ->
        {:noreply, State.select_provider_selector_result(state, -1)}

      code == "n" && ctrl?(mods) ->
        {:noreply, State.select_provider_selector_result(state, 1)}

      code == "enter" ->
        {:noreply, accept_provider_selection(state)}

      code in ["esc", "escape"] ->
        {:noreply, State.deactivate_provider_selector(state) |> State.mark_dirty()}

      code == "o" && ctrl?(mods) ->
        {:noreply, State.deactivate_provider_selector(state) |> State.mark_dirty()}

      true ->
        {:noreply, state}
    end
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

      state.activity_focused? ->
        {:noreply, State.move_activity_selection(state, 1)}

      true ->
        handle_text_key("j", mods, state)
    end
  end

  defp handle_key("k", _mods, %{activity_focused?: true} = state),
    do: {:noreply, State.move_activity_selection(state, -1)}

  defp handle_key("enter", mods, state) do
    cond do
      state.activity_focused? and input_blank?(state) ->
        {:noreply, %{state | show_activity_details: true} |> State.mark_dirty()}

      state.show_activity_details and input_blank?(state) ->
        {:noreply, State.mark_dirty(state)}

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

    state =
      if state.show_activity_details do
        %{state | show_activity_details: false}
      else
        State.blur_activity(state)
      end

    {:noreply, state |> close_panels() |> State.mark_dirty()}
  end

  defp handle_key("tab", _mods, %{show_commands: true} = state),
    do: {:noreply, accept_command_completion(state)}

  defp handle_key("tab", _mods, state),
    do:
      {:noreply,
       %{state | show_activity_details: not state.show_activity_details} |> State.mark_dirty()}

  defp handle_key("p", mods, state) do
    if ctrl?(mods) do
      cond do
        state.show_commands ->
          {:noreply, %{state | command_selected: max(0, state.command_selected - 1)}}

        state.show_activity_details ->
          {:noreply, select_activity(state, 1)}

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

        state.show_activity_details ->
          {:noreply, select_activity(state, -1)}

        true ->
          {:noreply, navigate_history(state, :down)}
      end
    else
      handle_text_key("n", mods, state)
    end
  end

  defp handle_key("r", mods, %{show_activity_details: true} = state) do
    if ctrl?(mods),
      do: {:noreply, rewind_selected_checkpoint(state)},
      else: handle_text_key("r", mods, state)
  end

  defp handle_key("f", mods, %{show_activity_details: true} = state) do
    if ctrl?(mods),
      do: {:noreply, fork_selected_checkpoint(state)},
      else: handle_text_key("f", mods, state)
  end

  defp handle_key("a", mods, %{show_activity_details: true} = state) do
    if ctrl?(mods),
      do: {:noreply, abandon_selected_branch(state)},
      else: handle_text_key("a", mods, state)
  end

  defp handle_key("up", mods, state) do
    cond do
      state.show_commands ->
        {:noreply, select_command(state, -1)}

      state.show_activity_details or state.activity_focused? ->
        {:noreply, State.move_activity_selection(state, if(shift?(mods), do: -5, else: -1))}

      not input_blank?(state) ->
        handle_text_key("up", mods, state)

      true ->
        if shift?(mods) or alt?(mods) do
          {:noreply, State.scroll_activity_up(state)}
        else
          {:noreply, State.scroll_up(state)}
        end
    end
  end

  defp handle_key("down", mods, state) do
    cond do
      state.show_commands ->
        {:noreply, select_command(state, 1)}

      state.show_activity_details or state.activity_focused? ->
        {:noreply, State.move_activity_selection(state, if(shift?(mods), do: 5, else: 1))}

      not input_blank?(state) ->
        handle_text_key("down", mods, state)

      true ->
        if shift?(mods) or alt?(mods) do
          {:noreply, State.scroll_activity_down(state)}
        else
          {:noreply, State.scroll_down(state)}
        end
    end
  end

  defp handle_key(code, _mods, %{show_activity_details: true} = state)
       when code in ["page_up", "pageup", "pgup"] do
    {:noreply, State.activity_page(state, :up)}
  end

  defp handle_key(code, _mods, %{show_activity_details: true} = state)
       when code in ["page_down", "pagedown", "pgdown"] do
    {:noreply, State.activity_page(state, :down)}
  end

  defp handle_key(code, _mods, %{activity_focused?: true} = state)
       when code in ["page_up", "pageup", "pgup"] do
    {:noreply, State.activity_page(state, :up)}
  end

  defp handle_key(code, _mods, %{activity_focused?: true} = state)
       when code in ["page_down", "pagedown", "pgdown"] do
    {:noreply, State.activity_page(state, :down)}
  end

  defp handle_key(code, _mods, %{activity_focused?: true} = state)
       when code in ["home", "g"] do
    {:noreply, State.activity_home(state)}
  end

  defp handle_key(code, _mods, %{activity_focused?: true} = state)
       when code in ["end", "G"] do
    {:noreply, State.activity_end(state)}
  end

  defp handle_key("o", mods, state) do
    if ctrl?(mods) do
      {:noreply, toggle_provider_selector(state)}
    else
      handle_text_key("o", mods, state)
    end
  end

  defp handle_key(code, mods, state), do: handle_text_key(code, mods, state)

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

  defp alt?(nil), do: false
  defp alt?(mods), do: "alt" in mods

  defp shift?(nil), do: false
  defp shift?(mods), do: "shift" in mods

  defp scroll_activity(state, :up) do
    if state.show_activity_details do
      select_activity(state, 1)
    else
      State.scroll_activity_up(state, 3)
    end
  end

  defp scroll_activity(state, :down) do
    if state.show_activity_details do
      select_activity(state, -1)
    else
      State.scroll_activity_down(state, 3)
    end
  end

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
      State.add_message(state, :system, "Agent is still working.")
    end
  end

  defp submit(state) do
    if State.paused?(state) do
      # When paused, don't process regular messages - they'll be handled by /continue
      value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

      cond do
        value == "" ->
          state

        String.starts_with?(value, "/") ->
          ExRatatui.textarea_set_value(state.textarea, "")
          state = maybe_record_command_history(state, value)
          run_command(%{state | show_commands: false}, String.trim_leading(value, "/"))

        true ->
          # Keep the message in the textarea for /continue to pick up
          state
      end
    else
      value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

      cond do
        value == "" ->
          state

        state.pending_login? ->
          ExRatatui.textarea_set_value(state.textarea, "")
          complete_login(%{state | show_commands: false}, value)

        state.pending_provider_key? ->
          ExRatatui.textarea_set_value(state.textarea, "")
          complete_provider_key(%{state | show_commands: false}, value)

        String.starts_with?(value, "/") ->
          ExRatatui.textarea_set_value(state.textarea, "")
          state = maybe_record_command_history(state, value)
          run_command(%{state | show_commands: false}, String.trim_leading(value, "/"))

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

  defp select_activity(state, offset) do
    State.move_activity_selection(state, offset)
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
  defp run_command(state, "timeline"), do: open_timeline(state)
  defp run_command(state, "timeline last"), do: open_timeline(State.activity_end(state))

  defp run_command(state, "checkpoint rewind " <> checkpoint_id),
    do: rewind_checkpoint(state, String.trim(checkpoint_id))

  defp run_command(state, "checkpoint fork " <> checkpoint_id),
    do: fork_checkpoint(state, String.trim(checkpoint_id))

  defp run_command(state, "checkpoint abandon " <> branch_id),
    do: abandon_branch(state, String.trim(branch_id))

  defp run_command(state, "timeline clear"),
    do:
      state
      |> Map.merge(%{
        activity: [],
        selected_activity: 0,
        activity_scroll_offset: 0,
        show_activity_details: false
      })
      |> State.add_message(
        :system,
        "Cleared visible timeline activity. Session history was not changed."
      )

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
      |> State.add_message(:system, "Execution interrupted. Current branch is paused.")
    else
      State.add_message(
        state,
        :system,
        "Session paused. Type your improved direction to resume."
      )
      |> Map.update!(:session, fn
        nil -> nil
        session -> Session.interrupt(session, "Session paused by user.")
      end)
      |> State.pause()
    end
  end

  defp run_command(state, "continue") do
    handle_continue_command(state, "")
  end

  defp run_command(state, "continue " <> alignment) do
    handle_continue_command(state, alignment)
  end

  defp run_command(state, "resume") do
    handle_continue_command(state, "")
  end

  defp run_command(state, "resume " <> alignment) do
    handle_continue_command(state, alignment)
  end

  defp run_command(state, "drop") do
    if state.worker != nil do
      Process.exit(state.worker, :kill)
    end

    if state.screen_type == :research and state.session != nil do
      session_id = state.session.session_id
      research_dir = Path.join([System.user_home!(), ".beamcore", "research", session_id])
      File.rm_rf(research_dir)
      if state.session.log_file, do: File.rm(state.session.log_file)

      opts = [
        workspace_root: state.session.workspace_root,
        screen_type: state.screen_type,
        roles: state.session.roles
      ]

      new_session = Session.new(state.session.client, opts)

      %{
        state
        | session: new_session,
          messages: [],
          activity: [],
          selected_activity: 0,
          activity_scroll_offset: 0,
          worker: nil,
          status: :idle
      }
      |> State.add_message(
        :system,
        "Research session dropped and reset. All artifacts and logs for this session have been deleted. You can start a new topic."
      )
    else
      State.add_message(state, :system, "Drop command is only available in research sessions.")
    end
  end

  defp run_command(state, "kick") do
    if state.worker != nil do
      State.add_message(state, :system, "Agent is already working.")
    else
      state = State.resume(state)

      prompt =
        "Continue with the next steps in your research plan. Use tools to gather and analyze information."

      state
      |> State.add_message(:system, "Kicking research loop...")
      |> start_turn(prompt, nil)
    end
  end

  defp run_command(state, command) do
    result =
      Commands.execute(command, state.session,
        output: fn message -> send(self(), {:runtime_event, self(), {:assistant, message}}) end
      )

    apply_command_result(result, state, command)
  end

  defp handle_continue_command(state, alignment) do
    alignment = String.trim(alignment)
    state = State.resume(state)

    state =
      Map.update!(state, :session, fn
        nil -> nil
        session -> Session.resume_interrupted(session, "Session resumed.")
      end)

    cond do
      alignment != "" ->
        state
        |> State.add_message(:user, alignment)
        |> start_turn(alignment, nil)

      state.screen_type == :research ->
        prompt =
          "Continue with the next steps in your research plan. Use tools to gather and analyze information."

        state
        |> State.add_message(:system, "Resuming research session...")
        |> start_turn(prompt, nil)

      true ->
        state
        |> State.add_message(:system, "Session resumed.")
    end
  end

  defp open_timeline(state) do
    if State.timeline_items(state) == [] do
      State.add_message(state, :system, "Timeline is empty.")
    else
      %{
        state
        | show_activity_details: true,
          selected_activity: min(state.selected_activity, length(State.timeline_items(state)) - 1)
      }
      |> State.mark_dirty()
    end
  end

  defp rewind_selected_checkpoint(state) do
    case selected_checkpoint_id(state) do
      nil -> State.add_message(state, :system, "No checkpoint selected.")
      checkpoint_id -> rewind_checkpoint(state, checkpoint_id)
    end
  end

  defp fork_selected_checkpoint(state) do
    case selected_checkpoint_id(state) do
      nil -> State.add_message(state, :system, "No checkpoint selected.")
      checkpoint_id -> fork_checkpoint(state, checkpoint_id)
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

  defp abandon_selected_branch(state) do
    branch_id =
      case selected_timeline_event(state) do
        %{timeline_event: %{branch_id: id}} -> id
        _ -> state.session && state.session.branch_id
      end

    if branch_id do
      abandon_branch(state, branch_id)
    else
      State.add_message(state, :system, "No branch selected.")
    end
  end

  defp rewind_checkpoint(state, checkpoint_id) do
    request_restore(state, checkpoint_id, :rewind)
  end

  defp fork_checkpoint(state, checkpoint_id) do
    request_restore(state, checkpoint_id, :fork)
  end

  defp request_restore(%{status: :restoring} = state, _checkpoint_id, _action) do
    State.add_message(state, :system, "Restore already in progress for this session.")
  end

  defp request_restore(state, checkpoint_id, action) do
    state = interrupt_worker(state)

    case Beamcore.Agent.RestoreCoordinator.restore_async(
           state.session,
           checkpoint_id,
           action,
           self()
         ) do
      {:accepted, restore_id} ->
        state
        |> State.select_checkpoint(checkpoint_id)
        |> State.set_status(:restoring)
        |> State.add_message(
          :system,
          "Restore #{restore_id} accepted for checkpoint #{checkpoint_id}."
        )

      {:error, reason} ->
        State.add_message(state, :system, reason)
    end
  end

  defp interrupt_worker(%{worker: nil} = state), do: state

  defp interrupt_worker(state) do
    Process.exit(state.worker, :kill)
    %{state | worker: nil, status: :paused}
  end

  defp abandon_branch(state, branch_id) do
    session = Session.abandon_branch(state.session, branch_id, "Branch abandoned by user.")

    state
    |> State.set_session(session)
    |> State.add_message(:system, "Marked branch #{branch_id} as abandoned.")
  end

  defp selected_checkpoint_id(state) do
    case selected_timeline_event(state) do
      %{timeline_event: %{checkpoint_id: checkpoint_id}} when is_binary(checkpoint_id) ->
        checkpoint_id

      _ ->
        state.selected_checkpoint_id || State.active_checkpoint_id(state.session)
    end
  end

  defp selected_timeline_event(state) do
    state
    |> State.timeline_items()
    |> Enum.at(state.selected_activity)
  end

  defp apply_command_result({:run_pending, session, content, policy}, state, _command) do
    state
    |> State.set_session(session)
    |> State.add_message(
      :system,
      "Executing legacy pending action once with its restricted policy."
    )
    |> start_turn(content, policy)
  end

  defp apply_command_result({:login_prompt, session}, state, _command) do
    state
    |> State.set_session(session)
    |> Map.put(:pending_login?, true)
    |> State.mark_dirty()
  end

  defp apply_command_result({:provider_select, session}, state, _command) do
    state
    |> State.set_session(session)
    |> State.activate_provider_selector()
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

  defp apply_command_result(session, state, "policy" <> _ = command) do
    state
    |> State.set_session(session)
    |> State.add_activity("policy", policy_activity_args(command), :done)
  end

  defp apply_command_result(session, state, "yolo" <> _ = command) do
    state
    |> State.set_session(session)
    |> State.add_activity("policy", %{"action" => "mode", "target" => command}, :done)
  end

  defp apply_command_result(session, state, _command), do: State.set_session(state, session)

  defp complete_login(state, token) do
    state = %{state | pending_login?: false, history_index: nil}

    case Commands.store_login_token(token) do
      :ok ->
        state
        |> State.set_session(state.session)
        |> State.add_message(:system, Commands.login_saved_message())

      {:error, :empty_value} ->
        State.add_message(state, :system, "Login token was empty; nothing was saved.")
    end
  end

  defp policy_activity_args(command) do
    command
    |> String.split(" ", trim: true)
    |> case do
      ["policy"] -> %{"action" => "show"}
      ["policy", action | rest] -> %{"action" => action, "target" => Enum.join(rest, " ")}
      _other -> %{"action" => "updated"}
    end
  end

  defp start_turn(state, content, policy) do
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
            Loop.send_message(session, content, nil, policy,
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
    |> State.deactivate_provider_selector()
  end

  defp toggle_provider_selector(state) do
    if state.provider_selector_active? do
      State.deactivate_provider_selector(state)
    else
      State.activate_provider_selector(state)
    end
  end

  defp accept_provider_selection(state) do
    selected_idx = state.provider_selector_selected
    results = state.provider_selector_results

    case Enum.at(results, selected_idx) do
      nil ->
        state
        |> State.deactivate_provider_selector()

      %{name: name, config: config} = provider ->
        state = State.deactivate_provider_selector(state)

        # Check if the provider needs configuration (key input)
        needs_key? =
          cond do
            not Beamcore.Provider.Registry.provider_requires_key?(name) -> false
            provider.configured? -> false
            is_map(config) and not is_nil(Map.get(config, "api_key")) -> false
            true -> true
          end

        if needs_key? do
          state
          |> Map.put(:pending_provider_key?, true)
          |> Map.put(:pending_provider_name, name)
          |> State.add_message(
            :system,
            "Provider '#{name}' requires an API key. Please type your API key and press Enter:"
          )
          |> State.mark_dirty()
        else
          Beamcore.Config.set_active_provider(state.screen_type, name)
          Beamcore.Config.set_active_provider(name)
          new_session = Beamcore.Agent.Chat.Session.set_primary_provider(state.session, name)
          new_model = new_session.roles.primary.model
          Beamcore.Config.set_active_model(state.screen_type, new_model)

          state
          |> State.set_session(new_session)
          |> State.add_message(:system, "Switched active provider to '#{name}'.")
          |> State.mark_dirty()
        end
    end
  end

  defp complete_provider_key(state, key) do
    provider = state.pending_provider_name

    state = %{
      state
      | pending_provider_key?: false,
        pending_provider_name: nil,
        history_index: nil
    }

    defaults = Map.get(Beamcore.Agent.Chat.Commands.provider_defaults(), provider, %{})
    base_url = Map.get(defaults, :base_url, "https://api.openai.com/v1")
    default_model = Map.get(defaults, :default_model, "default")

    Beamcore.Config.put_provider(provider, %{
      api_key: key,
      base_url: base_url,
      default_model: default_model
    })

    Beamcore.Config.set_active_provider(state.screen_type, provider)
    Beamcore.Config.set_active_provider(provider)
    Beamcore.Config.set_active_model(state.screen_type, default_model)

    new_session =
      Beamcore.Agent.Chat.Session.set_primary_provider(state.session, provider, default_model)

    state
    |> State.set_session(new_session)
    |> State.add_message(
      :system,
      "Provider '#{provider}' configured successfully and set as active."
    )
    |> State.mark_dirty()
  end

  @doc """
  Triggers the next research turn autonomously if the session is not completed or paused.
  """
  def maybe_auto_continue(state) do
    if auto_continue?(state) do
      prompt =
        "Continue with the next steps in your research plan. Use tools to gather and analyze information."

      start_turn(state, prompt, nil)
    else
      state
    end
  end

  defp auto_continue?(state) do
    state.screen_type == :research and
      state.status != :paused and
      state.session != nil and
      auto_continue_budget_remaining?(state.session) and
      not user_message_last?(state.session.messages) and
      not research_complete?(state.session.messages)
  end

  defp auto_continue_budget_remaining?(session) do
    limit =
      case System.get_env("BEAMCORE_RESEARCH_AUTO_CONTINUE_LIMIT") do
        value when is_binary(value) ->
          case Integer.parse(value) do
            {integer, ""} when integer >= 0 -> integer
            _ -> 4
          end

        _ ->
          4
      end

    completed =
      session.timeline
      |> List.wrap()
      |> Enum.count(fn event -> (event[:type] || event["type"]) == :completed end)

    completed < limit
  end

  defp user_message_last?(messages) do
    case List.last(messages) do
      nil ->
        true

      msg ->
        role = Map.get(msg, :role) || Map.get(msg, "role")
        role in [:user, "user"]
    end
  end

  defp research_complete?(messages) do
    case List.last(messages) do
      nil ->
        false

      msg ->
        content = Map.get(msg, :content) || Map.get(msg, "content")

        if is_binary(content) do
          String.contains?(content, "RESEARCH_COMPLETE")
        else
          false
        end
    end
  end

  defp key_press?(%{kind: kind}), do: kind in [nil, "press", :press]
end
