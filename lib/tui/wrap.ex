defmodule Beamcore.TUI.Wrap do
  @moduledoc """
  Width-aware wrapping helpers for TUI text.
  """

  @ellipsis "…"

  def lines(text, width) do
    width = max(width, 8)

    text
    |> to_string()
    |> String.split("\n")
    |> wrap_lines(width, false, [])
    |> Enum.reverse()
  end

  def markdown_lines(text, width) do
    text
    |> normalize_markdown_for_estimation()
    |> lines(width)
  end

  defp truncate_line(text, width) do
    width = max(width, 1)
    text = to_string(text)

    if String.length(text) <= width do
      text
    else
      String.slice(text, 0, max(width - 1, 0)) <> @ellipsis
    end
  end

  defp normalize_markdown_for_estimation(text), do: normalize_markdown_for_display(text)

  defp normalize_markdown_for_display(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> process_markdown_lines(false, [])
    |> Enum.join("\n")
  end

  defp process_markdown_lines([], _in_fence?, acc), do: Enum.reverse(acc)

  defp process_markdown_lines([line | rest], in_fence?, acc) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "```") do
      process_markdown_lines(rest, not in_fence?, acc)
    else
      if in_fence? do
        # Inside code block: preserve exactly as is
        process_markdown_lines(rest, true, [line | acc])
      else
        # Outside code block: apply filters and normalization
        cond do
          markdown_table_separator?(line) or markdown_rule?(line) ->
            process_markdown_lines(rest, false, acc)

          trimmed == "" ->
            case acc do
              [] -> process_markdown_lines(rest, false, acc)
              ["" | _] -> process_markdown_lines(rest, false, acc)
              _ -> process_markdown_lines(rest, false, ["" | acc])
            end

          true ->
            normalized = normalize_markdown_line(line)
            process_markdown_lines(rest, false, [normalized | acc])
        end
      end
    end
  end

  defp markdown_table_separator?(line) do
    line
    |> String.trim()
    |> then(&(Regex.match?(~r/^\|?[\s:|-]+\|?$/, &1) and String.contains?(&1, "-")))
  end

  defp markdown_rule?(line) do
    line
    |> String.trim()
    |> then(&Regex.match?(~r/^[-*_]{3,}$/, &1))
  end

  defp normalize_markdown_line(line) do
    line
    |> normalize_markdown_table_row()
    |> normalize_markdown_heading()
    |> normalize_markdown_list_marker()
    |> normalize_markdown_inline()
    |> String.trim_trailing()
  end

  defp normalize_markdown_heading(line) do
    trimmed = String.trim_leading(line)
    marks = trimmed |> String.graphemes() |> Enum.take_while(&(&1 == "#")) |> length()

    cond do
      marks in 1..6 and String.starts_with?(String.slice(trimmed, marks, 1), " ") ->
        "◆ " <> (String.slice(trimmed, marks, String.length(trimmed) - marks) |> String.trim())

      true ->
        line
    end
  end

  defp normalize_markdown_table_row(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "|") and String.ends_with?(trimmed, "|") do
      trimmed
      |> String.trim("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("  ·  ")
    else
      line
    end
  end

  defp normalize_markdown_inline(line) do
    line
    |> String.replace(~r/\*\*([^\s*](?:(?!\*\*).)*?[^\s*])\*\*/, "\\1")
    |> String.replace(~r/(?<![a-zA-Z0-9])__([^\s_](?:(?!__).)*?[^\s_])__(?![a-zA-Z0-9])/, "\\1")
    |> String.replace(~r/(?<!\*)\*([^\s*](?:[^*]*[^\s*])?)\*(?!\*)/, "\\1")
    |> String.replace(~r/(?<![a-zA-Z0-9])_([^\s_](?:[^_]*[^\s_])?)_(?![a-zA-Z0-9])/, "\\1")
    |> String.replace(~r/`([^`]+)`/, "\\1")
  end

  defp normalize_markdown_list_marker(line) do
    line
    |> String.replace(~r/^\s*[-*+]\s+/, "  • ")
    |> String.replace(~r/^\s*(\d+)\.\s+/, "  \\1. ")
  end

  defp wrap_lines([], _width, _code?, acc), do: acc

  defp wrap_lines([line | rest], width, code?, acc) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "```") ->
        wrap_lines(rest, width, not code?, [truncate_line(line, width) | acc])

      code? ->
        wrap_lines(rest, width, code?, [truncate_line(line, width) | acc])

      trimmed == "" ->
        wrap_lines(rest, width, code?, ["" | acc])

      true ->
        wrapped = wrap_paragraph(line, width)
        wrap_lines(rest, width, code?, Enum.reverse(wrapped) ++ acc)
    end
  end

  defp wrap_paragraph(line, width) do
    {prefix, body, continuation_prefix} = paragraph_prefix(line)

    body
    |> String.split(~r/\s+/, trim: true)
    |> wrap_words(width, prefix, continuation_prefix, "", [])
    |> case do
      [] -> [""]
      lines -> Enum.reverse(lines)
    end
  end

  defp paragraph_prefix(line) do
    leading = Regex.run(~r/^\s*/, line) |> List.first()
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "- ") ->
        {leading <> "- ", String.trim_leading(trimmed, "- "), leading <> "  "}

      String.starts_with?(trimmed, "* ") ->
        {leading <> "* ", String.trim_leading(trimmed, "* "), leading <> "  "}

      Regex.match?(~r/^\d+\.\s+/, trimmed) ->
        [marker] = Regex.run(~r/^\d+\.\s+/, trimmed)

        {leading <> marker, String.replace_prefix(trimmed, marker, ""),
         leading <> String.duplicate(" ", String.length(marker))}

      true ->
        {leading, trimmed, leading}
    end
  end

  defp wrap_words([], _width, _first_prefix, _cont_prefix, current, acc) do
    if current == "", do: acc, else: [current | acc]
  end

  defp wrap_words([word | rest], width, first_prefix, cont_prefix, "", acc) do
    available = max(width - String.length(first_prefix), 1)

    if String.length(word) > available do
      {chunk, remainder} = split_word(word, available)
      next_acc = [first_prefix <> chunk | acc]
      wrap_words([remainder | rest], width, cont_prefix, cont_prefix, "", next_acc)
    else
      wrap_words(rest, width, first_prefix, cont_prefix, first_prefix <> word, acc)
    end
  end

  defp wrap_words([word | rest], width, _first_prefix, cont_prefix, current, acc) do
    candidate = current <> " " <> word

    cond do
      String.length(candidate) <= width ->
        wrap_words(rest, width, cont_prefix, cont_prefix, candidate, acc)

      String.length(word) > max(width - String.length(cont_prefix), 1) ->
        available = max(width - String.length(cont_prefix), 1)
        {chunk, remainder} = split_word(word, available)

        wrap_words([remainder | rest], width, cont_prefix, cont_prefix, cont_prefix <> chunk, [
          current | acc
        ])

      true ->
        wrap_words(rest, width, cont_prefix, cont_prefix, cont_prefix <> word, [current | acc])
    end
  end

  defp split_word(word, width) do
    width = max(width - 1, 1)
    chunk = String.slice(word, 0, width) <> @ellipsis
    remainder = String.slice(word, width, String.length(word) - width)
    {chunk, remainder}
  end
end
