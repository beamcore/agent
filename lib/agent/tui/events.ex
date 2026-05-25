defmodule Beamcore.Agent.TUI.Events do
  @moduledoc """
  Event handling for the primary TUI.
  """

  alias Beamcore.Agent.Chat.{Commands, Loop}
  alias Beamcore.Agent.TUI.{History, State}
  alias ExRatatui.Event
  alias ExRatatui.Widgets.SlashCommands
  alias ExRatatui.Widgets.SlashCommands.Command

  @commands [
    %Command{name: "help", description: "Show commands and keybindings"},
    %Command{name: "new", description: "Start a fresh session"},
    %Command{name: "context", description: "Show compact session context"},
    %Command{name: "context clear", description: "Clear compact session context"},
    %Command{name: "confirm", description: "Execute the pending plan once"},
    %Command{name: "cancel", description: "Cancel the pending plan"},
    %Command{name: "yolo", description: "Enable all tools with unrestricted access"},
    %Command{name: "quit", description: "Exit", aliases: ["exit", "q"]}
  ]

  def commands, do: @commands

  def handle_event(event, state, opts \\ [])

  def handle_event(%Event.Key{} = event, state, opts) do
    code = normalize_code(event.code)
    mods = normalize_mods(event.modifiers)

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

  def handle_event(%Event.Mouse{} = event, state, _opts) do
    {width, height} = ExRatatui.terminal_size()

    areas =
      Beamcore.Agent.TUI.Layout.areas(%ExRatatui.Layout.Rect{
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

  def handle_runtime_event({:tool_finished, name, args, result}, state),
    do: State.update_activity(state, name, args, result)

  def handle_runtime_event(_event, state), do: state

  def finish_worker(state, session), do: State.finish_worker(state, session)

  defp handle_key("c", mods, state) do
    if ctrl?(mods), do: {:stop, state}, else: handle_text_key("c", mods, state)
  end

  defp handle_key(code, _mods, %{show_help: true} = state)
       when code in ["esc", "escape", "q", "enter", "space", "h", "?", "f1"] do
    {:noreply, close_panels(state)}
  end

  defp handle_key("s", mods, state) do
    if ctrl?(mods), do: {:noreply, submit(state)}, else: handle_text_key("s", mods, state)
  end

  defp handle_key("enter", mods, state) do
    if state.show_commands do
      {:noreply, execute_command(state)}
    else
      {:noreply, maybe_submit_or_newline(state, mods || [])}
    end
  end

  defp handle_key(code, _mods, state) when code in ["esc", "escape"] do
    state =
      state
      |> Map.put(:show_commands, false)
      |> Map.put(:command_matches, [])
      |> Map.put(:history_index, nil)

    ExRatatui.textarea_set_value(state.textarea, "")
    {:noreply, state |> close_panels() |> State.mark_dirty()}
  end

  defp handle_key("tab", _mods, state),
    do: {:noreply, %{state | show_activity_details: not state.show_activity_details}}

  defp handle_key("up", _mods, state) do
    cond do
      state.show_commands ->
        {:noreply, %{state | command_selected: max(0, state.command_selected - 1)}}

      state.show_activity_details ->
        max_index = max(length(state.activity) - 1, 0)
        {:noreply, %{state | selected_activity: min(state.selected_activity + 1, max_index)}}

      true ->
        {:noreply, navigate_history(state, :up)}
    end
  end

  defp handle_key("down", _mods, state) do
    cond do
      state.show_commands ->
        max_index = max(length(state.command_matches) - 1, 0)
        {:noreply, %{state | command_selected: min(state.command_selected + 1, max_index)}}

      state.show_activity_details ->
        {:noreply, %{state | selected_activity: max(state.selected_activity - 1, 0)}}

      true ->
        {:noreply, navigate_history(state, :down)}
    end
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

  defp scroll_activity(state, :up) do
    max_index = max(length(state.activity) - 1, 0)

    %{
      state
      | selected_activity: min(state.selected_activity + 1, max_index),
        show_activity_details: true
    }
    |> State.mark_dirty()
  end

  defp scroll_activity(state, :down) do
    %{state | selected_activity: max(state.selected_activity - 1, 0), show_activity_details: true}
    |> State.mark_dirty()
  end

  defp ctrl?(mods), do: "ctrl" in mods

  defp maybe_submit_or_newline(state, mods) do
    if "shift" in mods do
      insert_newline(state)
    else
      submit(state)
    end
  end

  defp insert_newline(state) do
    ExRatatui.textarea_handle_key(state.textarea, "enter", [])
    state
  end

  defp submit(%{worker: worker} = state) when not is_nil(worker),
    do: State.add_message(state, :system, "Agent is still working.")

  defp submit(state) do
    value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

    cond do
      value == "" ->
        state

      String.starts_with?(value, "/") ->
        ExRatatui.textarea_set_value(state.textarea, "")
        state = record_history(state, value)
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

  defp execute_command(state) do
    case Enum.at(state.command_matches, state.command_selected) do
      nil ->
        state

      %Command{name: name} ->
        ExRatatui.textarea_set_value(state.textarea, "")
        full_command = "/" <> name
        state = record_history(state, full_command)
        run_command(%{state | show_commands: false}, name)
    end
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

  defp run_command(state, command) when command in ["quit", "exit", "q"],
    do: %{state | status: :quit}

  defp run_command(%{show_help: true} = state, "help"), do: %{state | show_help: false}
  defp run_command(state, "help"), do: %{state | show_help: true}

  defp run_command(state, command) do
    result =
      Commands.execute(command, state.session,
        output: fn message -> send(self(), {:runtime_event, {:assistant, message}}) end
      )

    apply_command_result(result, state, command)
  end

  defp apply_command_result({:run_pending, session, content, policy}, state, _command) do
    state
    |> State.set_session(session)
    |> State.add_message(
      :system,
      "Confirmed pending plan. Executing once with its restricted policy."
    )
    |> start_turn(content, policy)
  end

  defp apply_command_result(session, state, "new") do
    %{state | session: session, messages: [], activity: [], selected_activity: 0}
    |> State.add_message(:system, "Started a fresh session.")
  end

  defp apply_command_result(session, state, _command), do: State.set_session(state, session)

  defp start_turn(state, content, policy) do
    parent = self()
    session = state.session

    {:ok, pid} =
      Task.start(fn ->
        updated =
          Loop.send_message(session, content, nil, policy,
            silent: true,
            event_handler: fn event -> send(parent, {:runtime_event, event}) end
          )

        send(parent, {:agent_done, self(), updated})
      end)

    State.start_worker(state, pid)
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

  defp normalize_code(code) when is_binary(code), do: code |> String.downcase()
  defp normalize_code(code) when is_atom(code), do: code |> Atom.to_string() |> String.downcase()
  defp normalize_code(code), do: code |> to_string() |> String.downcase()

  defp normalize_mods(nil), do: []

  defp normalize_mods(mods) when is_list(mods),
    do: Enum.map(mods, &normalize_code/1)

  defp normalize_mods(mod), do: [normalize_code(mod)]
end
