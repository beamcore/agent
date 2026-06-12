defmodule Beamcore.TUI.FileFinder do
  @moduledoc """
  Fuzzy file finder triggered by `@` in the text input.
  Lists workspace files (respecting .gitignore) and matches them
  against a query using subsequence fuzzy matching.
  """

  alias Beamcore.Agent.Tools.PathInput
  alias Beamcore.Agent.SafeCmd

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
        # Get text up to cursor position on this line
        text_before_cursor = String.slice(line, 0, col)

        # Find the last `@` preceded by whitespace or at the start
        case find_at_token(text_before_cursor) do
          nil ->
            :no_file_query

          {query, local_start} ->
            # Compute absolute character offset in the full value
            abs_start = line_offset(lines, row) + local_start
            # Token end is at cursor
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
      |> Enum.map(fn path -> {path, fuzzy_score(path, query)} end)
      |> Enum.filter(fn {_path, score} -> score > 0 end)
      |> Enum.sort_by(fn {_path, score} -> -score end)
      |> Enum.take(@max_results)
      |> Enum.map(fn {path, _score} -> path end)
    end
  end

  @doc """
  Loads the list of workspace files and directories, respecting .gitignore.
  Tries git ls-files, then rg --files, then Path.wildcard as fallback.
  Directories are derived from file paths and suffixed with `/`.
  Filters out noisy internal/build paths.
  """
  @spec load_files() :: [String.t()]
  def load_files do
    root = PathInput.workspace_root()

    file_paths =
      case git_ls_files(root) do
        {:ok, paths} -> paths
        {:error, _} -> rg_files_fallback(root)
      end

    dirs = extract_directories(file_paths)

    (file_paths ++ dirs)
    |> Enum.filter(&safe_workspace_entry?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- Private ---

  defp extract_directories(file_paths) do
    file_paths
    |> Enum.flat_map(fn path ->
      parts = path |> Path.split() |> Enum.drop(-1)

      parts
      |> Enum.scan(fn segment, acc -> acc <> "/" <> segment end)
    end)
    |> MapSet.new()
    |> Enum.map(&(&1 <> "/"))
  end

  defp find_at_token(text) do
    # Walk backwards from end to find the last valid @ trigger
    # Valid: @ at position 0, or preceded by whitespace
    case Regex.scan(~r/(?:^|(?<=\s))@([^\s\]]*)/, text, return: :index) do
      [] ->
        nil

      matches ->
        # Take the last match (closest to cursor)
        [full_match_index, capture_index] = List.last(matches)
        {full_start, full_len} = full_match_index
        {_cap_start, cap_len} = capture_index

        # The @ itself is at position full_start (or full_start + leading whitespace)
        at_pos =
          if full_start == 0 or String.at(text, full_start) == "@" do
            full_start
          else
            # preceded by whitespace, @ is one char after full_start
            full_start + 1
          end

        # Only trigger if the match extends to the end of the text (i.e. cursor is at/in the token)
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

  defp git_ls_files(root) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard"]

    case SafeCmd.run("git", args, cd: root, stderr_to_stdout: true, timeout: 10_000) do
      {:ok, output, 0} ->
        case String.split(output, "\n", trim: true) do
          [] -> {:error, :no_files}
          paths -> {:ok, paths}
        end

      _ ->
        {:error, :git_failed}
    end
  end

  defp rg_files_fallback(root) do
    case SafeCmd.run("rg", ["--files", root], stderr_to_stdout: true, timeout: 10_000) do
      {:ok, output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> relativize(root)

      _ ->
        # Final fallback: wildcard
        root
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> relativize(root)
    end
  end

  defp relativize(paths, root) do
    root_prefix = if String.ends_with?(root, "/"), do: root, else: root <> "/"

    Enum.map(paths, fn path ->
      if String.starts_with?(path, root_prefix) do
        String.trim_leading(path, root_prefix)
      else
        path
      end
    end)
  end

  defp safe_workspace_entry?(path) do
    normalized =
      path
      |> String.trim_trailing("/")
      |> Path.split()
      |> Enum.join("/")
      |> String.downcase()

    not Enum.any?(
      [
        ".git",
        "_build",
        "deps",
        "node_modules",
        ".elixir_ls",
        ".beamcore/snapshots",
        ".beamcore/recovery",
        ".beamcore/memory"
      ],
      fn hidden -> normalized == hidden or String.starts_with?(normalized, hidden <> "/") end
    )
  end

  @doc """
  Fuzzy subsequence score. Higher is better, 0 means no match.
  Rewards:
  - Consecutive character matches
  - Matches at path component boundaries (after `/` or `.`)
  - Shorter paths (relative to query length)
  """
  @spec fuzzy_score(String.t(), String.t()) :: number()
  def fuzzy_score(path, query) do
    path_down = String.downcase(path)
    query_down = String.downcase(query)

    case subsequence_match(path_down, query_down) do
      nil -> 0
      positions -> score_positions(positions, path_down, query_down)
    end
  end

  defp subsequence_match(path, query) do
    path_chars = String.graphemes(path)
    query_chars = String.graphemes(query)
    do_subsequence(path_chars, query_chars, 0, [])
  end

  defp do_subsequence(_path_chars, [], _idx, acc), do: Enum.reverse(acc)

  defp do_subsequence([], _query_chars, _idx, _acc), do: nil

  defp do_subsequence([p | p_rest], [q | q_rest] = query, idx, acc) do
    if p == q do
      do_subsequence(p_rest, q_rest, idx + 1, [idx | acc])
    else
      do_subsequence(p_rest, query, idx + 1, acc)
    end
  end

  defp score_positions(positions, path, _query) do
    path_len = String.length(path)

    # Base score for matching
    base = 10

    # Bonus for consecutive matches
    consecutive_bonus =
      positions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> b == a + 1 end)
      |> Kernel.*(3)

    # Bonus for boundary matches (start of path component)
    boundary_bonus =
      Enum.count(positions, fn pos ->
        pos == 0 or String.at(path, pos - 1) in ["/", ".", "_", "-"]
      end)
      |> Kernel.*(5)

    # Penalty for long paths (prefer shorter results)
    length_penalty = path_len / 100.0

    # Bonus for prefix match
    prefix_bonus = if 0 in positions, do: 4, else: 0

    base + consecutive_bonus + boundary_bonus + prefix_bonus - length_penalty
  end
end
