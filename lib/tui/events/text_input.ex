defmodule Beamcore.TUI.Events.TextInput do
  @moduledoc false

  alias Beamcore.TUI.{FileFinder, State, Trace}

  def handle_text_key(code, mods, state) do
    before = value(state)
    state = apply_key(code, mods, state)
    after_value = value(state)

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

  def value(%{input_value: "", textarea: textarea}) when not is_nil(textarea) do
    case ExRatatui.textarea_get_value(textarea) do
      "" -> ""
      mirror -> mirror
    end
  end

  def value(%{input_value: value}) when is_binary(value), do: value

  def value(%{textarea: textarea}) when not is_nil(textarea),
    do: ExRatatui.textarea_get_value(textarea)

  def value(_state), do: ""

  def cursor(%{input_value: "", textarea: textarea}) when not is_nil(textarea) do
    case ExRatatui.textarea_get_value(textarea) do
      "" -> {0, 0}
      _mirror -> ExRatatui.textarea_cursor(textarea)
    end
  end

  def cursor(%{input_value: value, input_cursor: cursor}) when is_binary(value),
    do: char_index_to_pos(value, clamp_cursor(value, cursor))

  def cursor(%{textarea: textarea}) when not is_nil(textarea),
    do: ExRatatui.textarea_cursor(textarea)

  def cursor(_state), do: {0, 0}

  def set_value(state, value, cursor \\ nil) when is_binary(value) do
    cursor = clamp_cursor(value, cursor || String.length(value))
    mirror_textarea(state, value)
    %{state | input_value: value, input_cursor: cursor}
  end

  def insert_content(state, content) when is_binary(content) do
    update_value(state, fn value, cursor ->
      insert_at(value, cursor, normalize_newlines(content))
    end)
  end

  def insert_newline(state), do: insert_content(state, "\n")

  def input_blank?(state), do: value(state) |> String.trim() == ""

  defp apply_key(code, mods, state) do
    cond do
      ctrl?(mods) or alt?(mods) ->
        state

      code == "backspace" ->
        update_value(state, &delete_before/2)

      code == "delete" ->
        update_value(state, &delete_at/2)

      code == "left" ->
        move_cursor(state, -1)

      code == "right" ->
        move_cursor(state, 1)

      code == "home" ->
        move_to_line_boundary(state, :home)

      code == "end" ->
        move_to_line_boundary(state, :end)

      code == "up" ->
        move_vertical(state, -1)

      code == "down" ->
        move_vertical(state, 1)

      code == "space" ->
        insert_content(state, " ")

      printable?(code) ->
        insert_content(state, code)

      true ->
        state
    end
  end

  def handle_file_finder_key(_code, _mods, state) do
    value = value(state)
    cursor_pos = cursor(state)

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
        value = value(state)
        cursor_pos = cursor(state)

        case FileFinder.parse(value, cursor_pos) do
          {:file_query, _query, start, end_pos} ->
            replacement = "@" <> file_path <> " "

            new_value =
              String.slice(value, 0, start) <>
                replacement <>
                String.slice(value, end_pos..-1//1)

            state
            |> set_value(new_value, start + String.length(replacement))
            |> State.deactivate_file_finder()

          :no_file_query ->
            state
        end
    end
  end

  defp update_value(state, fun) do
    value = value(state)
    cursor = clamp_cursor(value, Map.get(state, :input_cursor, String.length(value)))
    {new_value, new_cursor} = fun.(value, cursor)
    set_value(state, new_value, new_cursor)
  end

  defp insert_at(value, cursor, insert) do
    {left, right} = split_at(value, cursor)
    new_value = left <> insert <> right
    {new_value, cursor + String.length(insert)}
  end

  defp delete_before(value, 0), do: {value, 0}

  defp delete_before(value, cursor) do
    graphemes = String.graphemes(value)
    new_value = graphemes |> List.delete_at(cursor - 1) |> Enum.join()
    {new_value, cursor - 1}
  end

  defp delete_at(value, cursor) do
    graphemes = String.graphemes(value)

    if cursor >= length(graphemes) do
      {value, cursor}
    else
      {graphemes |> List.delete_at(cursor) |> Enum.join(), cursor}
    end
  end

  defp move_cursor(state, offset) do
    value = value(state)
    cursor = clamp_cursor(value, Map.get(state, :input_cursor, 0) + offset)
    set_value(state, value, cursor)
  end

  defp move_to_line_boundary(state, boundary) do
    value = value(state)
    cursor = clamp_cursor(value, Map.get(state, :input_cursor, 0))
    {row, _col} = char_index_to_pos(value, cursor)
    lines = String.split(value, "\n", trim: false)
    prefix = lines |> Enum.take(row) |> Enum.map(&(String.length(&1) + 1)) |> Enum.sum()

    target =
      case boundary do
        :home -> prefix
        :end -> prefix + String.length(Enum.at(lines, row, ""))
      end

    set_value(state, value, target)
  end

  defp move_vertical(state, delta) do
    value = value(state)
    cursor = clamp_cursor(value, Map.get(state, :input_cursor, 0))
    {row, col} = char_index_to_pos(value, cursor)
    lines = String.split(value, "\n", trim: false)
    target_row = (row + delta) |> max(0) |> min(max(length(lines) - 1, 0))
    target_col = min(col, String.length(Enum.at(lines, target_row, "")))

    target =
      lines
      |> Enum.take(target_row)
      |> Enum.map(&(String.length(&1) + 1))
      |> Enum.sum()
      |> Kernel.+(target_col)

    set_value(state, value, target)
  end

  defp split_at(value, cursor) do
    graphemes = String.graphemes(value)
    {left, right} = Enum.split(graphemes, cursor)
    {Enum.join(left), Enum.join(right)}
  end

  defp clamp_cursor(value, cursor), do: cursor |> max(0) |> min(String.length(value))

  defp char_index_to_pos(string, index) do
    sub_str = String.slice(string, 0, index)
    lines = String.split(sub_str, "\n", trim: false)
    row = length(lines) - 1
    col = String.length(List.last(lines))
    {row, col}
  end

  defp normalize_newlines(text),
    do: text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

  defp printable?(code), do: is_binary(code) and String.length(code) == 1

  defp mirror_textarea(%{textarea: textarea}, value) when not is_nil(textarea) do
    ExRatatui.textarea_set_value(textarea, value)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp mirror_textarea(_state, _value), do: :ok

  defp ctrl?(nil), do: false
  defp ctrl?(mods), do: "ctrl" in mods
  defp alt?(nil), do: false
  defp alt?(mods), do: "alt" in mods
end
