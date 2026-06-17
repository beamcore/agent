defmodule Beamcore.TUI.FileFinder.Fuzzy do
  @moduledoc false

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

    base = 10

    consecutive_bonus =
      positions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> b == a + 1 end)
      |> Kernel.*(3)

    boundary_bonus =
      Enum.count(positions, fn pos ->
        pos == 0 or String.at(path, pos - 1) in ["/", ".", "_", "-"]
      end)
      |> Kernel.*(5)

    length_penalty = path_len / 100.0

    prefix_bonus = if 0 in positions, do: 4, else: 0

    base + consecutive_bonus + boundary_bonus + prefix_bonus - length_penalty
  end
end
