defmodule Beamcore.TUI.FileFinder do
  @moduledoc """
  Fuzzy file finder triggered by `@` in the text input.
  Lists workspace files (respecting .gitignore) and matches them
  against a query using subsequence fuzzy matching.
  """

  alias Beamcore.TUI.FileFinder.{Fuzzy, Loader}

  @max_results 15

  @doc """
  Parses the textarea value and cursor position to find an active `@query` token.
  Returns `{:file_query, query, token_start, token_end}` or `:no_file_query`.

  The `@` must be at the start of input or preceded by whitespace to avoid
  triggering on email addresses or other `@` uses.
  """
  @spec parse(String.t(), {non_neg_integer(), non_neg_integer()}) ::
          {:file_query, String.t(), non_neg_integer(), non_neg_integer()} | :no_file_query
  def parse(value, {row, col}) do
    lines = String.split(value, "\n", trim: false)

    case Enum.at(lines, row) do
      nil ->
        :no_file_query

      line ->
        text_before_cursor = String.slice(line, 0, col)

        case find_at_token(text_before_cursor) do
          nil ->
            :no_file_query

          {query, local_start} ->
            abs_start = line_offset(lines, row) + local_start
            abs_end = line_offset(lines, row) + col
            {:file_query, query, abs_start, abs_end}
        end
    end
  end

  @doc """
  Searches files matching the given query using fuzzy subsequence matching.
  Uses a cached file list if provided, otherwise loads files fresh.
  """
  @spec search(String.t(), [String.t()] | nil) :: [String.t()]
  def search(query, file_cache \\ nil) do
    files = file_cache || load_files()

    query = String.trim_leading(query, "[")

    if query == "" do
      Enum.take(files, @max_results)
    else
      files
      |> Enum.map(fn path -> {path, Fuzzy.fuzzy_score(path, query)} end)
      |> Enum.filter(fn {_path, score} -> score > 0 end)
      |> Enum.sort_by(fn {_path, score} -> -score end)
      |> Enum.take(@max_results)
      |> Enum.map(fn {path, _score} -> path end)
    end
  end

  @doc """
  Loads workspace files and directories. Delegates to the Loader module.
  """
  @spec load_files() :: [String.t()]
  def load_files, do: Loader.load_files()

  # --- Private ---

  defp find_at_token(text) do
    case Regex.scan(~r/(?:^|(?<=\s))@([^\s\]]*)/, text, return: :index) do
      [] ->
        nil

      matches ->
        [full_match_index, capture_index] = List.last(matches)
        {full_start, full_len} = full_match_index
        {_cap_start, cap_len} = capture_index

        at_pos =
          if full_start == 0 or String.at(text, full_start) == "@" do
            full_start
          else
            full_start + 1
          end

        if full_start + full_len == String.length(text) do
          query = String.slice(text, at_pos + 1, cap_len)
          {query, at_pos}
        else
          nil
        end
    end
  end

  defp line_offset(lines, row) do
    lines
    |> Enum.take(row)
    |> Enum.reduce(0, fn line, acc -> acc + String.length(line) + 1 end)
  end
end
