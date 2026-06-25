defmodule Beamcore.TUI.Components.Input do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}

  @placeholder "Ask BeamCore, describe a change, or type /help"
  @cursor " "

  def widget(state) do
    title = "Ctrl+s send · @ files · / commands"

    %Paragraph{
      text: input_text(state),
      style: Theme.style(:input),
      wrap: false,
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.border(state.status),
        padding: {1, 1, 0, 0}
      }
    }
  end

  defp input_text(state) do
    value = Beamcore.TUI.Events.TextInput.value(state)

    if value == "" do
      [Line.new([Span.new(@placeholder, style: Theme.style(:muted))])]
    else
      render_lines(value, Beamcore.TUI.Events.TextInput.cursor(state))
    end
  rescue
    _error -> [Line.new([Span.new(@placeholder, style: Theme.style(:muted))])]
  catch
    _, _ -> [Line.new([Span.new(@placeholder, style: Theme.style(:muted))])]
  end

  defp render_lines(value, {cursor_row, cursor_col}) do
    value
    |> String.split("\n", trim: false)
    |> Enum.with_index()
    |> Enum.map(fn {line, row} ->
      if row == cursor_row do
        line_with_cursor(line, cursor_col)
      else
        Line.new([Span.new(line)])
      end
    end)
  end

  defp line_with_cursor(line, cursor_col) do
    {before_cursor, at_cursor, after_cursor} = split_cursor(line, cursor_col)

    Line.new([
      Span.new(before_cursor),
      Span.new(cursor_cell(at_cursor), style: Theme.style(:cursor)),
      Span.new(after_cursor)
    ])
  end

  defp split_cursor(line, cursor_col) do
    graphemes = String.graphemes(line)
    before_cursor = graphemes |> Enum.take(cursor_col) |> Enum.join()

    case Enum.drop(graphemes, cursor_col) do
      [] -> {before_cursor, @cursor, ""}
      [at_cursor | rest] -> {before_cursor, at_cursor, Enum.join(rest)}
    end
  end

  defp cursor_cell(""), do: @cursor
  defp cursor_cell(value), do: value
end
