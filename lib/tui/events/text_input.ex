defmodule Beamcore.TUI.Events.TextInput do
  @moduledoc false

  alias Beamcore.TUI.{FileFinder, State, Trace}

  def handle_text_key(code, mods, state) do
    before = ExRatatui.textarea_get_value(state.textarea)
    ExRatatui.textarea_handle_key(state.textarea, code, mods)
    after_value = ExRatatui.textarea_get_value(state.textarea)

    Trace.event(:text_input, %{
      code: code,
      modifiers: mods,
      mutated?: before != after_value,
      before_length: String.length(before),
      after_length: String.length(after_value)
    })

    state = %{state | history_index: nil} |> State.mark_dirty()
    state = handle_file_finder_key(code, mods, state)

    {:noreply, Beamcore.TUI.Events.Commands.refresh_commands(state)}
  end

  def insert_textarea_content(textarea, content) do
    # Use the optimized atomic insert function from ex_ratatui
    # This handles the insertion in one shot without manual cursor movement
    ExRatatui.textarea_insert_str(textarea, content)
  end

  def handle_file_finder_key(_code, _mods, state) do
    value = ExRatatui.textarea_get_value(state.textarea)
    cursor_pos = ExRatatui.textarea_cursor(state.textarea)

    case FileFinder.parse(value, cursor_pos) do
      {:file_query, query, _start, _end} ->
        case state.file_finder_cache do
          nil ->
            state
            |> request_file_finder_cache()
            |> State.activate_file_finder(query, [])

          cache ->
            results = FileFinder.search(query, cache)

            if state.file_finder_active? do
              State.update_file_finder_query(state, query, results)
            else
              State.activate_file_finder(state, query, results)
            end
        end

      :no_file_query ->
        if state.file_finder_active? do
          State.deactivate_file_finder(state)
        else
          state
        end
    end
  end

  defp request_file_finder_cache(%{file_finder_loading?: true} = state), do: state

  defp request_file_finder_cache(state) do
    send(self(), :load_file_finder_cache)
    %{state | file_finder_loading?: true}
  end

  def accept_file_finder_selection(state) do
    case Enum.at(state.file_finder_results, state.file_finder_selected) do
      nil ->
        state

      file_path ->
        value = ExRatatui.textarea_get_value(state.textarea)
        cursor_pos = ExRatatui.textarea_cursor(state.textarea)

        case FileFinder.parse(value, cursor_pos) do
          {:file_query, _query, start, end_pos} ->
            replacement = "@" <> file_path <> " "

            new_value =
              String.slice(value, 0, start) <>
                replacement <>
                String.slice(value, end_pos..-1//1)

            ExRatatui.textarea_set_value(state.textarea, new_value)

            {target_row, target_col} =
              char_index_to_pos(new_value, start + String.length(replacement))

            move_textarea_cursor(state.textarea, target_row, target_col)
            State.deactivate_file_finder(state)

          :no_file_query ->
            state
        end
    end
  end

  defp move_textarea_cursor(textarea, target_row, target_col) do
    if target_row > 0 do
      Enum.each(1..target_row, fn _ -> ExRatatui.textarea_handle_key(textarea, "down") end)
    end

    if target_col > 0 do
      Enum.each(1..target_col, fn _ -> ExRatatui.textarea_handle_key(textarea, "right") end)
    end

    :ok
  end

  defp char_index_to_pos(string, index) do
    sub_str = String.slice(string, 0, index)
    lines = String.split(sub_str, "\n", trim: false)
    row = length(lines) - 1
    col = String.length(List.last(lines))
    {row, col}
  end
end
