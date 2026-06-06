defmodule Beamcore.TUI.ErrorFormatter do
  @moduledoc false

  @max_chars 1_200
  @max_lines 10

  def format(value) when is_binary(value) do
    value
    |> normalize_escaped_newlines()
    |> strip_control_chars()
    |> compact_lines()
    |> truncate()
  end

  def format(%{message: message}) when is_binary(message), do: format(message)

  def format(value) do
    value
    |> inspect(pretty: false, limit: 12, printable_limit: 800)
    |> format()
  end

  defp normalize_escaped_newlines(value) do
    if String.contains?(value, "\\n") and not String.contains?(value, "\n") do
      String.replace(value, "\\n", "\n")
    else
      value
    end
  end

  defp strip_control_chars(value) do
    String.replace(value, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
  end

  defp compact_lines(value) do
    lines =
      value
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.split(lines, @max_lines) do
      {visible, []} -> Enum.join(visible, "\n")
      {visible, hidden} -> Enum.join(visible, "\n") <> "\n… #{length(hidden)} more lines hidden"
    end
  end

  defp truncate(value) do
    if String.length(value) <= @max_chars do
      value
    else
      String.slice(value, 0, @max_chars - 1) <> "…"
    end
  end
end
