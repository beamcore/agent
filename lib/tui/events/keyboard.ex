defmodule Beamcore.TUI.Events.Keyboard do
  @moduledoc false

  alias Beamcore.TUI.State
  alias Beamcore.TUI.Events.{Commands, TextInput}

  def handle_key("c", mods, state) do
    if ctrl?(mods), do: handle_ctrl_c(state), else: text_key("c", mods, state)
  end

  def handle_key(code, _mods, %{show_help: true} = state)
      when code in ["esc", "escape", "q", "space", "h", "?", "f1"] do
    {:noreply, close_panels(state)}
  end

  def handle_key("s", mods, state) do
    if ctrl?(mods), do: {:noreply, Commands.submit(state)}, else: text_key("s", mods, state)
  end

  def handle_key("a", mods, state) do
    if ctrl?(mods) do
      select_all_text(state.textarea)
      {:noreply, State.mark_dirty(state)}
    else
      text_key("a", mods, state)
    end
  end

  def handle_key(code, mods, %{file_finder_active?: true} = state) do
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
        {:noreply, TextInput.accept_file_finder_selection(state)}

      code in ["esc", "escape"] ->
        {:noreply, State.deactivate_file_finder(state) |> State.mark_dirty()}

      code == "tab" ->
        {:noreply, TextInput.accept_file_finder_selection(state)}

      true ->
        text_key(code, mods, state)
    end
  end

  def handle_key("j", mods, state) do
    if ctrl?(mods), do: {:noreply, insert_newline(state)}, else: text_key("j", mods, state)
  end

  def handle_key("enter", mods, state) do
    if ctrl?(mods),
      do: {:noreply, Commands.submit(state)},
      else: {:noreply, insert_newline(state)}
  end

  def handle_key(code, _mods, state) when code in ["esc", "escape"] do
    state =
      state
      |> Map.put(:show_commands, false)
      |> Map.put(:command_matches, [])
      |> Map.put(:history_index, nil)

    {:noreply, state |> close_panels() |> State.mark_dirty()}
  end

  def handle_key("tab", _mods, %{show_commands: true} = state),
    do: {:noreply, Commands.accept_command_completion(state)}

  def handle_key("tab", _mods, state), do: text_key("tab", [], state)

  def handle_key("p", mods, state) do
    if ctrl?(mods) do
      if state.show_commands do
        {:noreply, %{state | command_selected: max(0, state.command_selected - 1)}}
      else
        {:noreply, Commands.navigate_history(state, :up)}
      end
    else
      text_key("p", mods, state)
    end
  end

  def handle_key("n", mods, state) do
    if ctrl?(mods) do
      if state.show_commands do
        max_index = max(length(state.command_matches) - 1, 0)
        {:noreply, %{state | command_selected: min(state.command_selected + 1, max_index)}}
      else
        {:noreply, Commands.navigate_history(state, :down)}
      end
    else
      text_key("n", mods, state)
    end
  end

  def handle_key("up", mods, state) do
    cond do
      state.show_commands -> {:noreply, Commands.select_command(state, -1)}
      not Commands.input_blank?(state) -> text_key("up", mods, state)
      true -> {:noreply, State.scroll_up(state)}
    end
  end

  def handle_key("down", mods, state) do
    cond do
      state.show_commands -> {:noreply, Commands.select_command(state, 1)}
      not Commands.input_blank?(state) -> text_key("down", mods, state)
      true -> {:noreply, State.scroll_down(state)}
    end
  end

  def handle_key(code, _mods, state) when code in ["page_up", "pageup", "pgup"] do
    {:noreply, State.chat_page(state, :up)}
  end

  def handle_key(code, _mods, state) when code in ["page_down", "pagedown", "pgdown"] do
    {:noreply, State.chat_page(state, :down)}
  end

  def handle_key("o", mods, state), do: text_key("o", mods, state)
  def handle_key(code, mods, state), do: text_key(code, mods, state)

  def select_all_text(textarea) do
    ExRatatui.textarea_handle_key(textarea, ">", ["alt"])
    ExRatatui.textarea_handle_key(textarea, "end", [])
    ExRatatui.textarea_handle_key(textarea, "<", ["alt", "shift"])
    ExRatatui.textarea_handle_key(textarea, "home", ["shift"])
  end

  defp handle_ctrl_c(state) do
    if Commands.input_blank?(state) do
      desired = if worker_running?(state), do: :pause, else: :exit

      if state.ctrl_c_pending == desired do
        confirm_ctrl_c(desired, State.disarm_ctrl_c(state))
      else
        {:noreply, State.arm_ctrl_c(state, desired)}
      end
    else
      {:noreply, Commands.clear_input(state)}
    end
  end

  defp confirm_ctrl_c(:pause, state), do: {:noreply, Commands.run_command(state, "stop")}
  defp confirm_ctrl_c(:exit, state), do: {:stop, state}

  defp worker_running?(%{worker: worker}), do: not is_nil(worker)

  defp insert_newline(state) do
    ExRatatui.textarea_handle_key(state.textarea, "enter", [])
    %{state | history_index: nil} |> State.mark_dirty()
  end

  defp close_panels(state) do
    state
    |> Map.put(:show_help, false)
    |> Map.put(:show_commands, false)
  end

  defp text_key(code, mods, state), do: TextInput.handle_text_key(code, mods, state)

  defp ctrl?(nil), do: false
  defp ctrl?(mods), do: "ctrl" in mods
  defp alt?(nil), do: false
  defp alt?(mods), do: "alt" in mods
  defp shift?(nil), do: false
  defp shift?(mods), do: "shift" in mods
end
