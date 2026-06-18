defmodule Beamcore.TUI.Wrap do
  @moduledoc """
  Width-aware wrapping helpers for TUI text.
  """

  alias Beamcore.TUI.Wrap.Markdown

  @ellipsis "\u2026"

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
    |> Markdown.normalize_for_estimation()
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

  defp wrap_lines([], _width, _code?, acc), do: acc

  defp wrap_lines([line | rest], width, code?, acc) do
    trimmed = String.trim(line)

    cond do
      fence_open?(trimmed) ->
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

  defp fence_open?(line) do
    String.starts_with?(line, "```")
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
