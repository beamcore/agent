defmodule Beamcore.Agent.TUI.Events do
  @moduledoc """
  Event handling for the primary TUI.
  """

  alias Beamcore.Agent.Chat.{Commands, Loop}
  alias Beamcore.Agent.TUI.State
  alias ExRatatui.Event
  alias ExRatatui.Widgets.SlashCommands
  alias ExRatatui.Widgets.SlashCommands.Command

  @commands [
    %Command{name: "help", description: "Show commands and keybindings"},
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
    %Command{name: "yolo", description: "Enable all tools with unrestricted access"},
    %Command{name: "quit", description: "Exit", aliases: ["exit", "q"]}
  ]

  def commands, do: @commands

  def handle_event(%Event.Key{} = event, state) do
    code = normalize_code(event.code)
    mods = normalize_mods(event.modifiers)

    if key_press?(event) do
      handle_key(code, mods, state)
    else
      {:noreply, state}
    end
  end

  def handle_event(%Event.Resize{}, state), do: {:noreply, State.mark_dirty(state)}
  def handle_event(_event, state), do: {:noreply, state}

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

  defp handle_key(code, _mods, state) when code in ["esc", "escape"],
    do: {:noreply, close_panels(state)}

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
        {:noreply, State.scroll_up(state)}
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
        {:noreply, State.scroll_down(state)}
    end
  end

  defp handle_key(code, mods, state), do: handle_text_key(code, mods, state)

  defp handle_text_key(code, mods, state) do
    ExRatatui.textarea_handle_key(state.textarea, code, mods)
    {:noreply, refresh_commands(state)}
  end

  defp ctrl?(mods) when is_list(mods), do: "ctrl" in mods
  defp ctrl?(_mods), do: false

  defp maybe_submit_or_newline(state, mods) do
    if "shift" in mods do
      ExRatatui.textarea_handle_key(state.textarea, "enter", mods)
      state
    else
      submit(state)
    end
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
        run_command(%{state | show_commands: false}, String.trim_leading(value, "/"))

      true ->
        ExRatatui.textarea_set_value(state.textarea, "")

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
        run_command(%{state | show_commands: false}, name)
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
      "Executing legacy pending action once with its restricted policy."
    )
    |> start_turn(content, policy)
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

  defp apply_command_result(session, state, _command), do: State.set_session(state, session)

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
