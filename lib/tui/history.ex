defmodule Beamcore.TUI.History do
  @moduledoc """
  Manages persistent TUI user input message history stored in ~/.agent/history.json.
  """

  @history_file Path.expand("~/.agent/history.json")

  @doc """
  Returns the path to the history file.
  """
  def history_path, do: Application.get_env(:agent, :history_path, @history_file)

  @doc """
  Loads the history entries from the history file.
  Returns a list of strings in chronological order (oldest to newest).
  """
  def load do
    path = history_path()

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim_trailing(&1, "\n"))
      |> Stream.filter(&(&1 != ""))
      |> Stream.map(&decode_line/1)
      |> Stream.filter(&(&1 != nil))
      |> Enum.to_list()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Appends a non-empty string to the history file as a single JSON line.
  Skips if the entry matches the most recent history entry.
  """
  def append(input) do
    input = String.trim(input)

    if input != "" do
      path = history_path()
      File.mkdir_p!(Path.dirname(path))

      last_entry = get_last_entry(path)

      if input != last_entry do
        case Jason.encode(input) do
          {:ok, json_str} ->
            File.write!(path, json_str <> "\n", [:append])

          _ ->
            :ok
        end
      end
    end
  rescue
    _ -> :ok
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, val} when is_binary(val) -> val
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp get_last_entry(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.take(-1)
      |> case do
        [line] -> line |> String.trim_trailing("\n") |> decode_line()
        _ -> nil
      end
    else
      nil
    end
  end
end
