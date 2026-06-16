defmodule Beamcore.TUI.Components.Chat.DiffRenderer do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  def render(label, content, wrap_width) do
    body_width = max(wrap_width - 2, 10)
    col_width = div(body_width - 5, 2) |> max(10)

    {header, diff_part} =
      case String.split(to_string(content), "\n\n", parts: 2) do
        [hdr, diff] -> {hdr, diff}
        [hdr] -> {hdr, ""}
      end

    header_lines =
      header
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        %Line{spans: [%Span{content: "  " <> line, style: Theme.style(:muted)}]}
      end)

    diff_lines = String.split(diff_part, ~r/\r?\n/)

    {parsed, pending_del, pending_add} =
      Enum.reduce(diff_lines, {[], [], []}, fn line, {acc, dels, adds} ->
        cond do
          String.starts_with?(line, "---") or String.starts_with?(line, "+++") ->
            {acc, dels, adds}

          String.starts_with?(line, "@@") ->
            acc = flush(acc, dels, adds, col_width)
            hunk = parse_hunk(line)
            hunk_line = %Line{spans: [%Span{content: hunk, style: Theme.style(:accent)}]}
            {acc ++ [hunk_line], [], []}

          String.starts_with?(line, "-") ->
            {acc, dels ++ [String.slice(line, 1..-1//1)], adds}

          String.starts_with?(line, "+") ->
            {acc, dels, adds ++ [String.slice(line, 1..-1//1)]}

          true ->
            {flush(acc, dels, adds, col_width), [], []}
        end
      end)

    final = flush(parsed, pending_del, pending_add, col_width)
    prefix = label_prefix(label)

    first = %Line{
      spans: [%Span{content: "#{prefix} #{label}", style: Theme.style(:accent)}]
    }

    all = [first | header_lines] ++ final

    [
      {%Paragraph{text: all, style: Theme.style(:muted), wrap: false}, length(all)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end

  defp flush(acc, [], [], _col), do: acc

  defp flush(acc, deletions, additions, col) do
    max_len = max(length(deletions), length(additions))

    lines =
      if max_len == 0 do
        []
      else
        Enum.map(0..(max_len - 1), fn i ->
          del = Enum.at(deletions, i) || ""
          add = Enum.at(additions, i) || ""

          del_style = if del == "", do: Theme.style(:muted), else: Theme.style(:error)
          add_style = if add == "", do: Theme.style(:muted), else: Theme.style(:done)

          %Line{
            spans: [
              %Span{content: "  " <> pad(del, col), style: del_style},
              %Span{content: " | ", style: Theme.style(:subtle)},
              %Span{content: pad(add, col), style: add_style}
            ]
          }
        end)
      end

    acc ++ lines
  end

  defp parse_hunk(line) do
    case Regex.run(~r/@@ -(\d+),?\d* \+(\d+),?\d* @@/, line) do
      [_, orig, _] -> "  Line #{orig}:"
      _ -> "  Change:"
    end
  end

  defp pad(text, width) do
    text = to_string(text)
    len = String.length(text)

    cond do
      len == width -> text
      len < width -> text <> String.duplicate(" ", width - len)
      true -> String.slice(text, 0, max(width - 3, 0)) <> "..."
    end
  end

  defp label_prefix("Modify File"), do: "\u00BB"
  defp label_prefix(label), do: label |> to_string() |> String.slice(0, 1)
end
