defmodule Beamcore.Agent.Tools.Modify do
  @moduledoc """
  Unified tool to create, overwrite, and edit files.
  """
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Unified tool to create, replace, or edit files.
  - To create/replace: provide `content`.
  - To edit: provide `edits` (search-and-replace blocks).
  """

  def name, do: "modify_file"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Relative workspace path of the target file."
            },
            content: %{
              type: "string",
              description: "New file content (omit if using `edits`)."
            },
            dry_run: %{
              type: "boolean",
              description: "Validate changes without writing to disk. Defaults to false."
            },
            edits: %{
              type: "array",
              description: "Targeted search-and-replace edits. Must be non-overlapping.",
              items: %{
                type: "object",
                properties: %{
                  search: %{
                    type: "string",
                    description: "Literal block of code to search for."
                  },
                  replace: %{
                    type: "string",
                    description: "New code to replace it with."
                  }
                },
                required: ["search", "replace"]
              }
            }
          },
          required: ["path"]
        }
      }
    }
  end

  def execute(params) do
    file_path =
      Map.get(params, "path") || Map.get(params, "filePath") || raise(KeyError, key: "path")

    content = Map.get(params, "content")
    edits = Map.get(params, "edits")
    dry_run = Map.get(params, "dry_run", false)

    cond do
      is_nil(content) and is_nil(edits) ->
        "Error: Either 'content' or 'edits' must be provided."

      not is_nil(content) and not is_nil(edits) and edits != [] ->
        "Error: Provide either 'content' (for full file write/overwrite) or 'edits' (for targeted edits), not both."

      not is_nil(content) ->
        handle_full_write(file_path, content, dry_run)

      not is_nil(edits) ->
        handle_targeted_edits(file_path, edits, dry_run)
    end
  end

  # ---------------------------------------------------------------------------
  # Full File Write/Overwrite
  # ---------------------------------------------------------------------------

  defp handle_full_write(file_path, content, dry_run) do
    content = content |> sanitize_obfuscated_emails()

    with :ok <- ProjectPolicy.allowed_write_path?(file_path),
         {:ok, expanded_path} <- PathSafety.resolve(file_path, allow_missing: true) do
      original_content =
        case File.read(expanded_path) do
          {:ok, orig} -> orig
          _ -> ""
        end

      diff = generate_diff(file_path, original_content, content)

      if dry_run do
        "Dry-run succeeded: File #{file_path} would be written." <>
          if(diff != "", do: "\n\n" <> diff, else: "")
      else
        expanded_path |> Path.dirname() |> File.mkdir_p!()

        case atomic_write(expanded_path, content) do
          :ok ->
            "Successfully wrote to #{expanded_path}" <>
              if(diff != "", do: "\n\n" <> diff, else: "")

          {:error, reason} ->
            "Error writing file #{expanded_path}: #{reason}"
        end
      end
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Targeted Edits
  # ---------------------------------------------------------------------------

  defp handle_targeted_edits(file_path, edits, dry_run) do
    with :ok <- ProjectPolicy.allowed_write_path?(file_path),
         {:ok, expanded_path} <- PathSafety.resolve(file_path) do
      case File.read(expanded_path) do
        {:ok, original_bytes} ->
          process_targeted_edits(expanded_path, file_path, original_bytes, edits, dry_run)

        {:error, reason} ->
          "Error reading file #{expanded_path}: #{reason}"
      end
    else
      {:error, reason} -> PathSafety.error(reason)
    end
  end

  defp process_targeted_edits(expanded_path, file_path, original_bytes, edits, dry_run) do
    {has_bom?, content} = strip_bom(original_bytes)
    line_ending = detect_line_ending(content)
    le_char = if line_ending == :crlf, do: "\r\n", else: "\n"

    file_lines = String.split(content, ~r/\r?\n/)

    # 1. Match all edits against the file content
    case match_all_edits(file_lines, edits) do
      {:ok, matched_ranges} ->
        # 2. Check for overlaps among matched ranges
        case check_overlaps(matched_ranges) do
          :ok ->
            # 3. Apply the edits in reverse order of starting index
            new_lines = apply_matched_edits(file_lines, matched_ranges)
            new_content = Enum.join(new_lines, le_char)

            if new_content == content do
              "Error: No changes made to #{file_path}. The replacements produced identical content."
            else
              final = if has_bom?, do: <<0xEF, 0xBB, 0xBF>> <> new_content, else: new_content
              diff = generate_diff(file_path, original_bytes, final)

              if dry_run do
                "Dry-run succeeded: File #{file_path} would be updated." <>
                  if(diff != "", do: "\n\n" <> diff, else: "")
              else
                case atomic_write(expanded_path, final) do
                  :ok ->
                    "Successfully updated #{expanded_path}" <>
                      if(diff != "", do: "\n\n" <> diff, else: "")

                  {:error, reason} ->
                    "Error writing file #{expanded_path}: #{reason}"
                end
              end
            end

          {:error, {:overlap, idx1, idx2}} ->
            "Error: Edit blocks #{idx1} and #{idx2} overlap in #{file_path}. Merge them or target disjoint regions."
        end

      {:error, :not_found, idx, search_string} ->
        report_not_found_diagnostic(content, search_string, idx, line_ending)

      {:error, {:ambiguous, line_numbers}, idx, _search_string} ->
        "Error: Search block at edits[#{idx}] is ambiguous. It occurs #{length(line_numbers)} times in the file at lines: #{Enum.join(line_numbers, ", ")}. Please provide more surrounding context lines."
    end
  end

  # ---------------------------------------------------------------------------
  # Splicing and Overlap Checks
  # ---------------------------------------------------------------------------

  defp match_all_edits(file_lines, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, idx}, {:ok, acc} ->
      search_str = sanitize_obfuscated_emails(Map.fetch!(edit, "search"))
      replace_str = sanitize_obfuscated_emails(Map.fetch!(edit, "replace"))

      search_lines = String.split(search_str, ~r/\r?\n/)
      replace_lines = String.split(replace_str, ~r/\r?\n/)

      case find_unique_match(file_lines, search_lines) do
        {:ok, start_idx} ->
          match_data = %{
            idx: idx,
            start_line: start_idx,
            end_line: start_idx + length(search_lines) - 1,
            orig_first: Enum.at(file_lines, start_idx),
            search_first: Enum.at(search_lines, 0),
            replace_lines: replace_lines
          }

          {:cont, {:ok, [match_data | acc]}}

        {:error, :not_found} ->
          {:halt, {:error, :not_found, idx, search_str}}

        {:error, {:ambiguous, line_indices}} ->
          line_numbers = Enum.map(line_indices, &(&1 + 1))
          {:halt, {:error, {:ambiguous, line_numbers}, idx, search_str}}
      end
    end)
  end

  defp check_overlaps(matched_ranges) do
    sorted = Enum.sort_by(matched_ranges, & &1.start_line)

    sorted
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn [prev, curr] ->
      if prev.end_line >= curr.start_line do
        {:error, {:overlap, prev.idx, curr.idx}}
      end
    end)
  end

  defp apply_matched_edits(file_lines, matched_ranges) do
    # Sort in reverse start_line order to prevent index shifting
    sorted_reverse = Enum.sort_by(matched_ranges, & &1.start_line, :desc)

    Enum.reduce(sorted_reverse, file_lines, fn match, acc ->
      aligned_replace =
        align_indentation(match.orig_first, match.search_first, match.replace_lines)

      replace_range(acc, match.start_line, match.end_line, aligned_replace)
    end)
  end

  defp replace_range(file_lines, start_idx, end_idx, new_lines) do
    before_lines = Enum.slice(file_lines, 0, start_idx)
    after_start = end_idx + 1
    after_lines = Enum.slice(file_lines, after_start..-1//1)
    before_lines ++ new_lines ++ after_lines
  end

  # ---------------------------------------------------------------------------
  # Indentation Alignment
  # ---------------------------------------------------------------------------

  defp align_indentation(orig_first, search_first, replace_lines) do
    orig_indent = measure_indentation(orig_first || "")
    search_indent = measure_indentation(search_first || "")

    orig_len = String.length(orig_indent)
    search_len = String.length(search_indent)
    diff = orig_len - search_len

    cond do
      diff > 0 ->
        spaces = String.duplicate(" ", diff)

        Enum.map(replace_lines, fn line ->
          if line == "", do: "", else: spaces <> line
        end)

      diff < 0 ->
        Enum.map(replace_lines, fn line ->
          strip_indentation(line, abs(diff))
        end)

      true ->
        replace_lines
    end
  end

  defp measure_indentation(line) do
    case Regex.run(~r/^\s+/, line) do
      [indent] -> indent
      nil -> ""
    end
  end

  defp strip_indentation(line, count) do
    case Regex.run(~r/^\s+/, line) do
      [spaces] ->
        strip_len = min(count, String.length(spaces))
        String.slice(line, strip_len..-1//1)

      nil ->
        line
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-Tiered Normalized Search
  # ---------------------------------------------------------------------------

  defp find_unique_match(file_lines, search_lines) do
    # Tier 1: Exact lines match
    t1_file = Enum.map(file_lines, &normalize_tier1/1)
    t1_search = Enum.map(search_lines, &normalize_tier1/1)

    case find_sublist_indices(t1_file, t1_search) do
      [idx] ->
        {:ok, idx}

      indices when length(indices) > 1 ->
        {:error, {:ambiguous, indices}}

      [] ->
        # Tier 2: Whitespace & quote normalized match
        t2_file = Enum.map(file_lines, &normalize_tier2/1)
        t2_search = Enum.map(search_lines, &normalize_tier2/1)

        case find_sublist_indices(t2_file, t2_search) do
          [idx] ->
            {:ok, idx}

          indices when length(indices) > 1 ->
            {:error, {:ambiguous, indices}}

          [] ->
            # Tier 3: Comment insensitive match
            t3_file = Enum.map(file_lines, &normalize_tier3/1)
            t3_search = Enum.map(search_lines, &normalize_tier3/1)

            case find_sublist_indices(t3_file, t3_search) do
              [idx] ->
                {:ok, idx}

              indices when length(indices) > 1 ->
                {:error, {:ambiguous, indices}}

              [] ->
                {:error, :not_found}
            end
        end
    end
  end

  defp find_sublist_indices(list, sublist) do
    sublist_len = length(sublist)

    if sublist_len == 0 do
      []
    else
      list
      |> Stream.chunk_every(sublist_len, 1, :discard)
      |> Stream.with_index()
      |> Enum.filter(fn {chunk, _idx} -> chunk == sublist end)
      |> Enum.map(fn {_, idx} -> idx end)
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization Definitions
  # ---------------------------------------------------------------------------

  defp normalize_tier1(line), do: line

  defp normalize_tier2(line) do
    cleaned =
      line
      |> String.replace(
        ~r/[\x{2018}\x{2019}\x{201A}\x{201B}\x{201C}\x{201D}\x{201E}\x{201F}]/u,
        "'"
      )
      |> String.replace(~r/["`]/, "'")
      |> String.replace(~r/,\s*$/, "")
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    Regex.replace(~r/\s*([^\w\s])\s*/u, cleaned, fn _, char -> char end)
  end

  defp normalize_tier3(line) do
    line
    |> String.replace(~r/(\s+#|\s+\/\/|^#|^\/\/).*$/, "")
    |> normalize_tier2()
  end

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {true, rest}
  defp strip_bom(content), do: {false, content}

  defp detect_line_ending(content) do
    case :binary.match(content, "\r\n") do
      {_, _} -> :crlf
      :nomatch -> :lf
    end
  end

  defp atomic_write(path, content) do
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp generate_diff(path, old_content, new_content) do
    tmp_old = Path.join(System.tmp_dir!(), "diff_old_#{System.unique_integer([:positive])}")
    tmp_new = Path.join(System.tmp_dir!(), "diff_new_#{System.unique_integer([:positive])}")

    File.write!(tmp_old, old_content)
    File.write!(tmp_new, new_content)

    try do
      case System.cmd("diff", [
             "-u",
             "--label",
             "a/#{path}",
             "--label",
             "b/#{path}",
             tmp_old,
             tmp_new
           ]) do
        {diff_out, _status} -> diff_out
      end
    rescue
      _ -> ""
    after
      File.rm(tmp_old)
      File.rm(tmp_new)
    end
  end

  defp sanitize_obfuscated_emails(content) when is_binary(content) do
    String.replace(content, ~r/\[email[\s\x{00A0}]*protected\]/iu, "$@")
  end

  # ---------------------------------------------------------------------------
  # Fuzzy Diagnostics
  # ---------------------------------------------------------------------------

  defp report_not_found_diagnostic(content, search_string, idx, line_ending) do
    le = if line_ending == :crlf, do: "\r\n", else: "\n"
    file_lines = String.split(content, le)
    search_lines = search_string |> String.replace("\r\n", "\n") |> String.split("\n")
    total = length(file_lines)

    case find_best_fuzzy_match(file_lines, search_lines) do
      {:ok, best_idx, k, best_sim} ->
        preview_start = max(0, best_idx - 3)
        preview_end = min(total - 1, best_idx + k + 2)

        similar_lines =
          file_lines
          |> Enum.with_index(1)
          |> Enum.slice(preview_start, preview_end - preview_start + 1)
          |> Enum.map(fn {line, num} ->
            prefix =
              if num >= best_idx + 1 and num <= best_idx + k,
                do: "=> #{num}: ",
                else: "   #{num}: "

            prefix <> line
          end)
          |> Enum.join("\n")

        "Error: Search block at edits[#{idx}] not found in file.\n\nDid you mean the block at lines #{best_idx + 1}-#{best_idx + k} (similarity: #{Float.round(best_sim * 100, 1)}%)?\n#{similar_lines}"

      :error ->
        preview_lines =
          file_lines
          |> Enum.with_index(1)
          |> Enum.take(30)
          |> Enum.map(fn {line, num} -> "  #{num}: #{line}" end)
          |> Enum.join("\n")

        "Error: Search block at edits[#{idx}] not found in file.\n\nFile preview (first 30 lines):\n#{preview_lines}"
    end
  end

  defp find_best_fuzzy_match(file_lines, search_lines) do
    k = length(search_lines)
    total = length(file_lines)

    if total >= k and k > 0 do
      # Normalize search lines for comparison
      normalized_search = Enum.map(search_lines, &normalize_tier2/1)

      {best_idx, best_sim} =
        Enum.reduce(0..(total - k), {-1, 0.0}, fn i, {best_i, best_s} ->
          sub = Enum.slice(file_lines, i, k) |> Enum.map(&normalize_tier2/1)

          sim =
            Enum.zip(sub, normalized_search)
            |> Enum.map(fn {fl, ol} -> String.jaro_distance(fl, ol) end)
            |> Enum.sum()
            |> Kernel./(k)

          if sim > best_s, do: {i, sim}, else: {best_i, best_s}
        end)

      if best_sim > 0.4, do: {:ok, best_idx, k, best_sim}, else: :error
    else
      :error
    end
  end
end
