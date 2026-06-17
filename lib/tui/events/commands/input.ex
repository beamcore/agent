defmodule Beamcore.TUI.Events.Commands.Input do
  @moduledoc false

  alias Beamcore.TUI.{History, State}
  alias Beamcore.TUI.Events.Commands
  alias ExRatatui.Widgets.SlashCommands

  def submit(%{worker: worker} = state) when not is_nil(worker) do
    value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

    if value == "/stop" do
      ExRatatui.textarea_set_value(state.textarea, "")
      Commands.run_command(%{state | show_commands: false}, "stop")
    else
      State.add_message(
        state,
        :system,
        "Agent is still working. Press Ctrl+C to stop, or wait for it to finish."
      )
    end
  end

  def submit(state) do
    value = ExRatatui.textarea_get_value(state.textarea) |> String.trim()

    cond do
      value == "" ->
        state

      String.starts_with?(value, "/") ->
        command = String.trim_leading(value, "/")

        if command == "theme" do
          ExRatatui.textarea_set_value(state.textarea, "")
          Commands.run_command(%{state | show_commands: false}, command)
        else
          ExRatatui.textarea_set_value(state.textarea, "")
          state = maybe_record_command_history(state, value)
          Commands.run_command(%{state | show_commands: false}, command)
        end

      State.paused?(state) ->
        ExRatatui.textarea_set_value(state.textarea, "")
        state = record_history(state, value)
        Commands.resume_session(%{state | show_commands: false}, value)

      true ->
        ExRatatui.textarea_set_value(state.textarea, "")
        state = record_history(state, value)

        state
        |> State.add_message(:user, value)
        |> Commands.start_turn(value, nil)
        |> Map.put(:show_commands, false)
    end
  end

  def accept_command_completion(state) do
    case Enum.at(state.command_matches, state.command_selected) do
      nil ->
        state

      %SlashCommands.Command{name: name} ->
        ExRatatui.textarea_set_value(state.textarea, "/" <> name)

        %{state | show_commands: false, command_matches: [], command_selected: 0}
        |> State.mark_dirty()
    end
  end

  def clear_input(state) do
    ExRatatui.textarea_set_value(state.textarea, "")

    %{state | history_index: nil, file_finder_active?: false, file_finder_results: []}
    |> State.disarm_ctrl_c()
    |> refresh_commands()
  end

  def input_blank?(state) do
    state.textarea
    |> ExRatatui.textarea_get_value()
    |> String.trim()
    |> Kernel.==("")
  end

  def select_command(state, offset) do
    max_index = max(length(state.command_matches) - 1, 0)
    selected = state.command_selected + offset

    %{state | command_selected: selected |> max(0) |> min(max_index)}
    |> State.mark_dirty()
  end

  def navigate_history(state, :up) do
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

  def navigate_history(state, :down) do
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

  def refresh_commands(state) do
    value = ExRatatui.textarea_get_value(state.textarea)

    case SlashCommands.parse(value) do
      {:command, prefix} ->
        matches = SlashCommands.match_commands(commands(), prefix)

        %{state | show_commands: matches != [], command_matches: matches, command_selected: 0}
        |> State.mark_dirty()

      :no_command ->
        %{state | show_commands: false, command_matches: []}
        |> State.mark_dirty()
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

  defp maybe_record_command_history(state, value), do: record_history(state, value)

  defp commands do
    [
      %SlashCommands.Command{name: "help", description: "Show commands and keybindings"},
      %SlashCommands.Command{name: "env", description: "Print full env variables"},
      %SlashCommands.Command{name: "api list", description: "List all configured API providers"},
      %SlashCommands.Command{name: "api use ", description: "Switch active API provider"},
      %SlashCommands.Command{name: "api add ", description: "Add or update an API provider"},
      %SlashCommands.Command{
        name: "api delete ",
        description: "Delete an API provider configuration"
      },
      %SlashCommands.Command{name: "clear", description: "Clear visible chat messages"},
      %SlashCommands.Command{
        name: "compress",
        description: "Compress/rollover the session context"
      },
      %SlashCommands.Command{name: "new", description: "Start a fresh session"},
      %SlashCommands.Command{
        name: "stop",
        description: "Pause the session; type a message to resume"
      },
      %SlashCommands.Command{name: "quit", description: "Exit"},
      %SlashCommands.Command{name: "exit", description: "Exit"},
      %SlashCommands.Command{name: "q", description: "Exit"},
      %SlashCommands.Command{name: "theme", description: "Switch UI themes"}
    ]
  end
end
