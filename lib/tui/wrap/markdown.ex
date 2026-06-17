defmodule Beamcore.TUI.Wrap.Markdown do
  @moduledoc false

  def normalize_for_estimation(text), do: normalize_for_display(text)

  def normalize_for_display(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> process_lines(false, [])
    |> Enum.join("\n")
  end

  defp process_lines([], _in_fence?, acc), do: Enum.reverse(acc)

  defp process_lines([line | rest], in_fence?, acc) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "```") do
      process_lines(rest, not in_fence?, acc)
    else
      if in_fence? do
        process_lines(rest, true, [line | acc])
      else
        cond do
          table_separator?(line) or rule?(line) ->
            process_lines(rest, false, acc)

          trimmed == "" ->
            case acc do
              [] -> process_lines(rest, false, acc)
              ["" | _] -> process_lines(rest, false, acc)
              _ -> process_lines(rest, false, ["" | acc])
            end

          true ->
            normalized = normalize_line(line)
            process_lines(rest, false, [normalized | acc])
        end
      end
    end
  end

  defp table_separator?(line) do
    line
    |> String.trim()
    |> then(&(Regex.match?(~r/^\|?[\s:|-]+\|?$/, &1) and String.contains?(&1, "-")))
  end

  defp rule?(line) do
    line
    |> String.trim()
    |> then(&Regex.match?(~r/^[-*_]{3,}$/, &1))
  end

  defp normalize_line(line) do
    line
    |> normalize_table_row()
    |> normalize_heading()
    |> normalize_list_marker()
    |> normalize_inline()
    |> String.trim_trailing()
  end

  defp normalize_heading(line) do
    trimmed = String.trim_leading(line)
    marks = trimmed |> String.graphemes() |> Enum.take_while(&(&1 == "#")) |> length()

    cond do
      marks in 1..6 and String.starts_with?(String.slice(trimmed, marks, 1), " ") ->
        "\u25C6 " <>
          (String.slice(trimmed, marks, String.length(trimmed) - marks) |> String.trim())

      true ->
        line
    end
  end

  defp normalize_table_row(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "|") and String.ends_with?(trimmed, "|") do
      trimmed
      |> String.trim("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("  \u00B7  ")
    else
      line
    end
  end

  defp normalize_inline(line) do
    line
    |> String.replace(~r/\*\*([^\s*](?:(?!\*\*).)*?[^\s*])\*\*/, "\\1")
    |> String.replace(~r/(?<![a-zA-Z0-9])__([^\s_](?:(?!__).)*?[^\s_])__(?![a-zA-Z0-9])/, "\\1")
    |> String.replace(~r/(?<!\*)\*([^\s*](?:[^*]*[^\s*])?)\*(?!\*)/, "\\1")
    |> String.replace(~r/(?<![a-zA-Z0-9])_([^\s_](?:[^_]*[^\s_])?)_(?![a-zA-Z0-9])/, "\\1")
    |> String.replace(~r/`([^`]+)`/, "\\1")
  end

  defp normalize_list_marker(line) do
    line
    |> String.replace(~r/^\s*[-*+]\s+/, "  \u2022 ")
    |> String.replace(~r/^\s*(\d+)\.\s+/, "  \\1. ")
  end
end
