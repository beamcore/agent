defmodule Beamcore.Agent.Tools.Edit do
  @moduledoc """
  Tool to replace exact strings in a file.

  All matching and splicing operations use byte-level semantics (`:binary.*` and
  `binary_part/3`) to guarantee correctness with any encoding, including multi-byte
  UTF-8 characters. File writes are atomic (temp file + rename).
  """
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Replace exact literal text in a file. Provide old_string (the exact text to find)
  and new_string (the replacement). For files with multiple occurrences of old_string,
  use start_line/end_line to disambiguate. For multiple edits in one call, use the
  edits array parameter instead of old_string/new_string.
  """

  def name, do: "edit"

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
              description: "The workspace-relative path to the file to modify."
            },
            old_string: %{
              type: "string",
              description: "The exact literal text to find and replace."
            },
            new_string: %{
              type: "string",
              description: "The replacement text."
            },
            start_line: %{
              type: "integer",
              description:
                "Optional. The 1-based line number where the search for old_string should begin."
            },
            end_line: %{
              type: "integer",
              description:
                "Optional. The 1-based line number where the search for old_string should end."
            },
            dry_run: %{
              type: "boolean",
              description:
                "Optional. If true, validates the edit without writing changes to the file. Defaults to false."
            },
            edits: %{
              type: "array",
              description:
                "Optional. One or more targeted replacements applied atomically against the original file content. Do not include overlapping edits.",
              items: %{
                type: "object",
                properties: %{
                  old_string: %{
                    type: "string",
                    description: "The exact literal text to find."
                  },
                  new_string: %{
                    type: "string",
                    description: "The replacement text."
                  }
                },
                required: ["old_string", "new_string"]
              }
            }
          },
          required: ["path"]
        }
      }
    }
  end

  def execute(params) do
    path = Map.fetch!(params, "path")
    dry_run = Map.get(params, "dry_run", false)

    with :ok <- ProjectPolicy.allowed_write_path?(path),
         {:ok, expanded_path} <- PathSafety.resolve(path) do
      case Beamcore.Agent.Tools.FileMutationQueue.with_lock(expanded_path, 5000, fn ->
             case File.read(expanded_path) do
               {:ok, content} ->
                 process_edit(expanded_path, content, params, dry_run)

               {:error, reason} ->
                 "Error reading file #{expanded_path}: #{reason}"
             end
           end) do
        {:error, :lock_timeout} ->
          "Error: Could not acquire lock for #{expanded_path} (timeout after 5s)."

        result ->
          result
      end
    else
      {:error, reason} ->
        PathSafety.error(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Core
  # ---------------------------------------------------------------------------

  defp process_edit(expanded_path, original_bytes, params, dry_run) do
    # 1. Strip BOM (preserve for restoration)
    {has_bom?, content} = strip_bom(original_bytes)

    # 2. Detect line ending style
    line_ending = detect_line_ending(content)

    # 3. Parse edits from params
    edits = parse_edits(params)

    # 4. Line range is only meaningful for single edits
    {start_line, end_line} =
      if length(edits) == 1,
        do: {Map.get(params, "start_line"), Map.get(params, "end_line")},
        else: {nil, nil}

    # 5. Find and validate all matches
    case find_all_matches(content, edits, line_ending, start_line, end_line) do
      {:ok, matched_edits} ->
        # 6. Apply edits via byte-level splicing
        new_content = apply_edits(content, matched_edits, line_ending)

        if new_content == content do
          if length(edits) == 1,
            do: "Error: No changes would be made to the file.",
            else:
              "Error: No changes made to #{expanded_path}. The replacements produced identical content."
        else
          # 7. Restore BOM if originally present
          final =
            if has_bom?, do: <<0xEF, 0xBB, 0xBF>> <> new_content, else: new_content

          # 8. Generate unified diff for feedback
          diff =
            generate_diff(
              params["path"] || Path.basename(expanded_path),
              original_bytes,
              final
            )

          if dry_run do
            "Dry-run succeeded: #{expanded_path} would be updated." <>
              if(diff != "", do: "\n\n" <> diff, else: "")
          else
            # 9. Atomic write (temp file + rename)
            case atomic_write(expanded_path, final) do
              :ok ->
                "Successfully updated #{expanded_path}" <>
                  if(diff != "", do: "\n\n" <> diff, else: "")

              {:error, reason} ->
                "Error writing file #{expanded_path}: #{reason}"
            end
          end
        end

      {:error, :empty_old_string, _idx, _old} ->
        "Error: old_string must not be empty."

      {:error, :not_found, idx, old_string} ->
        if length(edits) == 1 do
          report_not_found_diagnostic(content, old_string, start_line, end_line, line_ending)
        else
          "Error: Could not find edits[#{idx}] in #{expanded_path}. The old_string must match exactly including all whitespace and newlines."
        end

      {:error, {:ambiguous, line_numbers}, idx, _old} ->
        if length(edits) == 1 do
          "Error: old_string is ambiguous. It occurs #{length(line_numbers)} times in the file at lines: #{Enum.join(line_numbers, ", ")}."
        else
          "Error: Found #{length(line_numbers)} occurrences of edits[#{idx}] in #{expanded_path}. Each old_string must be unique. Please provide more context to make it unique."
        end

      {:error, {:overlap, prev_idx, curr_idx}} ->
        "Error: edits[#{prev_idx}] and edits[#{curr_idx}] overlap in #{expanded_path}. Merge them into one edit or target disjoint regions."
    end
  end

  # ---------------------------------------------------------------------------
  # Matching — all offsets are byte-level via :binary.*
  # ---------------------------------------------------------------------------

  defp find_all_matches(content, edits, line_ending, start_line, end_line) do
    result =
      edits
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {edit, idx}, acc ->
        case find_single_match(content, edit.old_string, line_ending, start_line, end_line) do
          {:ok, offset, length, adapted_old} ->
            match = %{
              idx: idx,
              offset: offset,
              length: length,
              new_string: edit.new_string,
              adapted_old: adapted_old
            }

            {:cont, [match | acc]}

          {:error, reason} ->
            {:halt, {:error, reason, idx, edit.old_string}}
        end
      end)

    case result do
      {:error, _, _, _} = err ->
        err

      matches ->
        sorted = Enum.sort_by(matches, & &1.offset)

        case check_overlaps(sorted) do
          :ok -> {:ok, sorted}
          {:error, _} = err -> err
        end
    end
  end

  defp find_single_match(content, old_string, line_ending, start_line, end_line) do
    primary = adapt_to_line_ending(old_string, line_ending)

    if byte_size(primary) == 0 do
      {:error, :empty_old_string}
    else
      # Build candidate search strings in priority order:
      # 1. Primary line-ending adaptation
      # 2. Alternative line-ending adaptation (handles mixed-ending files)
      # 3. Unicode-normalized variants (handles LLM smart quotes → ASCII)
      alt = adapt_to_line_ending(old_string, other_line_ending(line_ending))

      candidates =
        Enum.uniq([
          primary,
          alt,
          normalize_unicode_chars(primary),
          normalize_unicode_chars(alt)
        ])

      Enum.reduce_while(candidates, {:error, :not_found}, fn candidate, _acc ->
        case try_binary_match(content, candidate, start_line, end_line) do
          {:error, :not_found} -> {:cont, {:error, :not_found}}
          result -> {:halt, result}
        end
      end)
    end
  end

  defp try_binary_match(content, search, start_line, end_line) do
    matches = :binary.matches(content, search)
    has_range = not is_nil(start_line) or not is_nil(end_line)

    case {matches, has_range} do
      {[], _} ->
        {:error, :not_found}

      {[{offset, len}], _} ->
        {:ok, offset, len, search}

      {_, false} ->
        line_numbers =
          Enum.map(matches, fn {off, _} -> byte_offset_to_line(content, off) end)

        {:error, {:ambiguous, line_numbers}}

      {_, true} ->
        filter_by_line_range(content, search, matches, start_line, end_line)
    end
  end

  defp filter_by_line_range(content, search, matches, start_line, end_line) do
    {range_start, range_end} = line_range_to_byte_range(content, start_line, end_line)

    in_range =
      Enum.filter(matches, fn {off, len} ->
        off >= range_start and off + len <= range_end
      end)

    case in_range do
      [{offset, len}] ->
        {:ok, offset, len, search}

      [] ->
        # Retry with ±20 line tolerance for slightly-off line numbers
        tol_start = if start_line, do: max(1, start_line - 20), else: start_line
        tol_end = if end_line, do: end_line + 20, else: end_line
        {tol_start_b, tol_end_b} = line_range_to_byte_range(content, tol_start, tol_end)

        tol_matches =
          Enum.filter(matches, fn {off, len} ->
            off >= tol_start_b and off + len <= tol_end_b
          end)

        case tol_matches do
          [{offset, len}] ->
            {:ok, offset, len, search}

          [] ->
            {:error, :not_found}

          _ ->
            line_numbers =
              Enum.map(tol_matches, fn {off, _} -> byte_offset_to_line(content, off) end)

            {:error, {:ambiguous, line_numbers}}
        end

      _ ->
        line_numbers =
          Enum.map(in_range, fn {off, _} -> byte_offset_to_line(content, off) end)

        {:error, {:ambiguous, line_numbers}}
    end
  end

  defp check_overlaps(sorted_edits) do
    sorted_edits
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn [prev, curr] ->
      if prev.offset + prev.length > curr.offset do
        {:error, {:overlap, prev.idx, curr.idx}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Applying edits — byte-level splicing via binary_part/3
  # ---------------------------------------------------------------------------

  defp apply_edits(content, matched_edits, line_ending) do
    # Apply in reverse byte-offset order so earlier offsets remain valid
    matched_edits
    |> Enum.reverse()
    |> Enum.reduce(content, fn edit, acc ->
      adapted_new = adapt_to_line_ending(edit.new_string, line_ending)
      adapted_new = preserve_trailing_newline(edit.adapted_old, adapted_new, line_ending)

      before = binary_part(acc, 0, edit.offset)
      after_start = edit.offset + edit.length
      after_part = binary_part(acc, after_start, byte_size(acc) - after_start)

      before <> adapted_new <> after_part
    end)
  end

  # If old_string ended with a line ending but new_string does not, append one.
  # This prevents the extremely common LLM mistake of eating the separator between
  # the replaced block and the following line.
  defp preserve_trailing_newline(_old, new, _le) when byte_size(new) == 0, do: new

  defp preserve_trailing_newline(old, new, line_ending) do
    le = if line_ending == :crlf, do: "\r\n", else: "\n"

    if String.ends_with?(old, le) and not String.ends_with?(new, le) do
      new <> le
    else
      new
    end
  end

  # ---------------------------------------------------------------------------
  # Line ending handling
  # ---------------------------------------------------------------------------

  defp detect_line_ending(content) do
    case :binary.match(content, "\r\n") do
      {_, _} -> :crlf
      :nomatch -> :lf
    end
  end

  # Adapt text to the target line ending style.
  # First normalizes to LF, then expands to CRLF if needed.
  defp adapt_to_line_ending(text, :crlf) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end

  defp adapt_to_line_ending(text, :lf) do
    String.replace(text, "\r\n", "\n")
  end

  defp other_line_ending(:crlf), do: :lf
  defp other_line_ending(:lf), do: :crlf

  # ---------------------------------------------------------------------------
  # BOM handling
  # ---------------------------------------------------------------------------

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {true, rest}
  defp strip_bom(content), do: {false, content}

  # ---------------------------------------------------------------------------
  # Byte-offset / line-number utilities
  # ---------------------------------------------------------------------------

  defp byte_offset_to_line(content, target_offset) do
    clamped = min(target_offset, byte_size(content))
    before = binary_part(content, 0, clamped)
    length(:binary.matches(before, "\n")) + 1
  end

  defp line_range_to_byte_range(content, start_line, end_line) do
    newline_positions = :binary.matches(content, "\n")
    total_bytes = byte_size(content)

    # Line N starts at byte 0 (for line 1) or right after the (N-1)th newline
    line_starts = [0 | Enum.map(newline_positions, fn {pos, _} -> pos + 1 end)]
    total_lines = length(line_starts)

    start_idx =
      if start_line, do: max(0, min(start_line - 1, total_lines - 1)), else: 0

    end_idx =
      if end_line,
        do: max(start_idx, min(end_line - 1, total_lines - 1)),
        else: total_lines - 1

    range_start = Enum.at(line_starts, start_idx, 0)

    range_end =
      if end_idx + 1 < length(line_starts),
        do: Enum.at(line_starts, end_idx + 1),
        else: total_bytes

    {range_start, range_end}
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  defp parse_edits(params) do
    case Map.get(params, "edits") do
      edits when is_list(edits) and edits != [] ->
        Enum.map(edits, &parse_edit_entry/1)

      edits when is_binary(edits) ->
        case Jason.decode(edits) do
          {:ok, decoded} when is_list(decoded) and decoded != [] ->
            Enum.map(decoded, &parse_edit_entry/1)

          _ ->
            [parse_single_edit(params)]
        end

      _ ->
        [parse_single_edit(params)]
    end
  end

  defp parse_edit_entry(edit) do
    %{
      old_string: sanitize_obfuscated_emails(Map.fetch!(edit, "old_string")),
      new_string: sanitize_obfuscated_emails(Map.fetch!(edit, "new_string"))
    }
  end

  defp parse_single_edit(params) do
    %{
      old_string: sanitize_obfuscated_emails(Map.fetch!(params, "old_string")),
      new_string: sanitize_obfuscated_emails(Map.fetch!(params, "new_string"))
    }
  end

  # ---------------------------------------------------------------------------
  # Atomic write — temp file + rename for crash safety
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Diff generation
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Error reporting — fuzzy diagnostics (read-only, never used for matching)
  # ---------------------------------------------------------------------------

  defp report_not_found_diagnostic(content, old_string, start_line, end_line, line_ending) do
    le = if line_ending == :crlf, do: "\r\n", else: "\n"
    file_lines = String.split(content, le)
    old_lines = old_string |> String.replace("\r\n", "\n") |> String.split("\n")
    total = length(file_lines)

    case find_best_fuzzy_match(file_lines, old_lines) do
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

        "Error: old_string not found in file.\n\nDid you mean the block at lines #{best_idx + 1}-#{best_idx + k} (similarity: #{Float.round(best_sim * 100, 1)}%)?\n#{similar_lines}"

      :error ->
        preview_start = if start_line, do: max(0, start_line - 6), else: 0
        preview_end = if end_line, do: min(total - 1, end_line + 4), else: min(total - 1, 29)

        preview_lines =
          file_lines
          |> Enum.with_index(1)
          |> Enum.slice(preview_start, preview_end - preview_start + 1)
          |> Enum.map(fn {line, num} -> "  #{num}: #{line}" end)
          |> Enum.join("\n")

        "Error: old_string not found in file.\n\nFile preview (lines #{preview_start + 1}-#{preview_end + 1}):\n#{preview_lines}"
    end
  end

  defp find_best_fuzzy_match(file_lines, old_lines) do
    k = length(old_lines)
    total = length(file_lines)

    if total >= k and k > 0 do
      {best_idx, best_sim} =
        Enum.reduce(0..(total - k), {-1, 0.0}, fn i, {best_i, best_s} ->
          sub = Enum.slice(file_lines, i, k)

          sim =
            Enum.zip(sub, old_lines)
            |> Enum.map(fn {fl, ol} -> String.jaro_distance(fl, ol) end)
            |> Enum.sum()
            |> Kernel./(k)

          if sim > best_s, do: {i, sim}, else: {best_i, best_s}
        end)

      if best_sim > 0.5, do: {:ok, best_idx, k, best_sim}, else: :error
    else
      :error
    end
  end

  # ---------------------------------------------------------------------------
  # Sanitization
  # ---------------------------------------------------------------------------

  defp sanitize_obfuscated_emails(content) when is_binary(content) do
    String.replace(content, ~r/\[email[\s\x{00A0}]*protected\]/iu, "$@")
  end

  # Normalize common Unicode typography to ASCII equivalents.
  # Only applied to the search string (old_string), never to file content.
  defp normalize_unicode_chars(text) do
    text
    |> String.replace(~r/[\x{2018}\x{2019}\x{201A}\x{201B}]/u, "'")
    |> String.replace(~r/[\x{201C}\x{201D}\x{201E}\x{201F}]/u, "\"")
    |> String.replace(~r/[\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]/u, "-")
    |> String.replace(~r/[\x{00A0}\x{2002}-\x{200A}\x{202F}\x{205F}\x{3000}]/u, " ")
  end
end
