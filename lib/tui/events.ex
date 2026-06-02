defmodule Beamcore.TUI.Events do
  @moduledoc """
  Event handling for the primary TUI.
  """

  alias Beamcore.Agent.Chat.{Commands, Loop}
  alias Beamcore.TUI.{History, State}
  alias ExRatatui.Event
  alias ExRatatui.Widgets.SlashCommands
  alias ExRatatui.Widgets.SlashCommands.Command

  @commands [
    %Command{name: "help", description: "Show commands and keybindings"},
    %Command{name: "env", description: "Print full env variables"},
    %Command{name: "login", description: "Configure your Mistral API key"},
    %Command{name: "logout", description: "Clear stored Beamcore login"},
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
    %Command{name: "yolo", description: "Toggle freedom mode"},
    %Command{name: "yolo on", description: "Bypass project policy for this session"},
    %Command{name: "yolo off", description: "Restore project policy for this session"},
    %Command{name: "stop", description: "Pause the session to add improved direction"},
    %Command{name: "continue", description: "Resume the paused session"},
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
    do: State.add_message(state, :assistant, content)

  def handle_runtime_event({:error, content}, state),
    do: State.add_message(state, :error, content)

  def handle_runtime_event({:tool_queued, name, args}, state),
    do: State.add_activity(state, name, args, :queued)

  def handle_runtime_event({:tool_running, name, args}, state),
    do: State.add_activity(State.set_status(state, :tool_running), name, args, :running)

  def handle_runtime_event({:tool_finished, "modify_file", args, result}, state) do
    state
    |> State.update_activity("modify_file", args, result)
    |> State.add_message(:tool, result)
  end

  def handle_runtime_event({:tool_finished, name, args, result}, state) do
    State.update_activity(state, name, args, result)
  end

  def handle_runtime_event(_event, state), do: state

  def finish_worker(state, session), do: State.finish_worker(state, session)

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

  defp handle_key("j", mods, state) do
    if ctrl?(mods), do: {:noreply, insert_newline(state)}, else: handle_text_key("j", mods, state)
  end

  defp handle_key("enter", mods, state) do
    cond do
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

  defp handle_key("up", mods, state) do
    cond do
      state.show_commands ->
        {:noreply, select_command(state, -1)}

      state.show_activity_details ->
        {:noreply, select_activity(state, if(shift?(mods), do: -5, else: -1))}

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

      state.show_activity_details ->
        {:noreply, select_activity(state, if(shift?(mods), do: 5, else: 1))}

      not input_blank?(state) ->
        handle_text_key("down", mods, state)

      true ->
        {:noreply, State.scroll_down(state)}
    end
  end

  defp handle_key(code, _mods, %{show_activity_details: true} = state)
       when code in ["page_up", "pageup", "pgup"] do
    {:noreply, select_activity(state, -5)}
  end

  defp handle_key(code, _mods, %{show_activity_details: true} = state)
       when code in ["page_down", "pagedown", "pgdown"] do
    {:noreply, select_activity(state, 5)}
  end

  defp handle_key(code, mods, state), do: handle_text_key(code, mods, state)

  defp handle_text_key(code, mods, state) do
    ExRatatui.textarea_handle_key(state.textarea, code, mods)
    state = %{state | history_index: nil}
    {:noreply, refresh_commands(state)}
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
    state
    |> Map.put(:show_activity_details, true)
    |> select_activity(1)
  end

  defp scroll_activity(state, :down) do
    state
    |> Map.put(:show_activity_details, true)
    |> select_activity(-1)
  end

  defp insert_newline(state) do
    ExRatatui.textarea_handle_key(state.textarea, "enter", [])

    state
    |> Map.put(:history_index, nil)
    |> State.mark_dirty()
  end

  defp submit(%{worker: worker} = state) when not is_nil(worker),
    do: State.add_message(state, :system, "Agent is still working.")

  defp submit(%{paused?: true} = state) do
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
  end

  defp submit(state) do
    value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

    cond do
      value == "" ->
        state

      state.pending_login? ->
        ExRatatui.textarea_set_value(state.textarea, "")
        complete_login(%{state | show_commands: false}, value)

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
    max_index = max(length(state.activity) - 1, 0)
    selected = state.selected_activity + offset

    %{state | selected_activity: selected |> max(0) |> min(max_index)}
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
  defp run_command(state, "timeline"), do: open_timeline(state)
  defp run_command(state, "timeline last"), do: open_timeline(%{state | selected_activity: 0})

  defp run_command(state, "timeline clear"),
    do:
      state
      |> Map.merge(%{activity: [], selected_activity: 0, show_activity_details: false})
      |> State.add_message(
        :system,
        "Cleared visible timeline activity. Session history was not changed."
      )

  defp run_command(state, "stop") do
    if state.worker != nil do
      State.add_message(
        state,
        :system,
        "Cannot pause while agent is working. Wait for current operation to complete."
      )
    else
      State.add_message(
        state,
        :system,
        "Session paused. Type your improved direction and use /continue to resume."
      )
      |> State.pause()
    end
  end

  defp run_command(state, "continue") do
    if State.paused?(state) do
      value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

      if value == "" do
        State.add_message(state, :system, "Please enter some direction before continuing.")
        |> State.pause()
      else
        ExRatatui.textarea_set_value(state.textarea, "")
        state = record_history(state, value)

        state
        |> State.add_message(:user, value)
        |> State.resume()
        |> start_turn(value, nil)
        |> Map.put(:show_commands, false)
      end
    else
      State.add_message(state, :system, "Session is not paused. Use /stop to pause first.")
    end
  end

  defp run_command(state, command) do
    result =
      Commands.execute(command, state.session,
        output: fn message -> send(self(), {:runtime_event, {:assistant, message}}) end
      )

    apply_command_result(result, state, command)
  end

  defp open_timeline(state) do
    if state.activity == [] do
      State.add_message(state, :system, "Timeline is empty.")
    else
      %{
        state
        | show_activity_details: true,
          selected_activity: min(state.selected_activity, length(state.activity) - 1)
      }
      |> State.mark_dirty()
    end
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

  defp apply_command_result(session, state, "new") do
    %{state | session: session, messages: [], activity: [], selected_activity: 0}
    |> State.add_message(:system, "Started a fresh session.")
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
        |> State.set_session(%{state.session | client: Beamcore.OpenAI.client()})
        |> State.add_message(:system, "Beamcore login saved.")

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
        updated =
          Loop.send_message(session, content, nil, policy,
            silent: true,
            event_handler: fn event -> send(parent, {:runtime_event, event}) end
          )

        send(parent, {:agent_done, self(), updated})
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

  defp close_panels(state),
    do: %{state | show_help: false, show_commands: false, show_activity_details: false}

  defp key_press?(%{kind: kind}), do: kind in [nil, "press", :press]
end
