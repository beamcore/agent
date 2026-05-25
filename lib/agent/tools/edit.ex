defmodule Beamcore.Agent.Tools.Edit do
  @moduledoc """
  Tool to replace exact string in a file with state-of-the-art matching, line-range,
  and whitespace tolerance.
  """
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Replace an exact old string with a new string in a specified file.
  Supports optional start_line and end_line parameters for precision and efficiency.
  Features robust exact and whitespace-normalized matching fallbacks, line ending preservation,
  and highly detailed error diagnostics.
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
              description: "The exact literal text to replace."
            },
            new_string: %{
              type: "string",
              description: "The exact literal text to replace old_string with."
            },
            start_line: %{
              type: "integer",
              description: "Optional. The 1-based line number where the search for old_string should begin."
            },
            end_line: %{
              type: "integer",
              description: "Optional. The 1-based line number where the search for old_string should end."
            },
            dry_run: %{
              type: "boolean",
              description: "Optional. If true, validates the edit without writing changes to the file. Defaults to false."
            }
          },
          required: ["path", "old_string", "new_string"]
        }
      }
    }
  end

  def execute(params) do
    path = Map.fetch!(params, "path")
    old_string = Map.fetch!(params, "old_string")
    new_string = Map.fetch!(params, "new_string")
    start_line = Map.get(params, "start_line")
    end_line = Map.get(params, "end_line")
    dry_run = Map.get(params, "dry_run", false)

    with {:ok, expanded_path} <- PathSafety.resolve(path) do
      case File.read(expanded_path) do
        {:ok, content} ->
          process_edit(expanded_path, content, old_string, new_string, start_line, end_line, dry_run)

        {:error, reason} ->
          "Error reading file #{expanded_path}: #{reason}"
      end
    else
      {:error, reason} ->
        PathSafety.error(reason)
    end
  end

  defp process_edit(expanded_path, content, old_string, new_string, start_line, end_line, dry_run) do
    sep = detect_line_ending(content)
    file_lines = String.split(content, sep)
    total_lines = length(file_lines)

    # 1. Parse and clamp line range constraints
    start_idx = if start_line, do: start_line - 1, else: 0
    end_idx = if end_line, do: end_line - 1, else: total_lines - 1

    start_idx = max(0, min(start_idx, total_lines - 1))
    end_idx = max(start_idx, min(end_idx, total_lines - 1))

    # Calculate tolerance search boundaries (+/- 20 lines)
    has_range = not is_nil(start_line) or not is_nil(end_line)
    search_start = if has_range, do: max(0, start_idx - 20), else: 0
    search_end = if has_range, do: min(total_lines - 1, end_idx + 20), else: total_lines - 1

    # 2. Try Exact Substring Match
    # Fast path if no range constraint and unique exact match in the file
    exact_match =
      cond do
        not has_range and String.contains?(content, old_string) ->
          case :binary.matches(content, old_string) do
            [{offset, len}] -> {:ok, :exact, offset, len}
            matches when length(matches) > 1 -> {:error, :ambiguous, find_all_occurrences_lines(content, old_string, sep)}
            _ -> :none
          end

        has_range ->
          # Check exact match inside specified range
          range_lines = Enum.slice(file_lines, start_idx, end_idx - start_idx + 1)
          range_content = Enum.join(range_lines, sep)

          if String.contains?(range_content, old_string) do
            case :binary.matches(range_content, old_string) do
              [{offset, len}] ->
                # Map range offset back to file offset
                # Calculate character length of lines before start_idx
                before_char_len =
                  if start_idx > 0 do
                    (Enum.take(file_lines, start_idx) |> Enum.join(sep) |> String.length()) + String.length(sep)
                  else
                    0
                  end
                {:ok, :exact_range, before_char_len + offset, len}

              matches when length(matches) > 1 ->
                # Within the range it's ambiguous, let's report occurrences
                {:error, :ambiguous, find_all_occurrences_lines(content, old_string, sep)}

              _ -> :none
            end
          else
            # Try within tolerance/expanded range
            tolerance_lines = Enum.slice(file_lines, search_start, search_end - search_start + 1)
            tolerance_content = Enum.join(tolerance_lines, sep)

            if String.contains?(tolerance_content, old_string) do
              case :binary.matches(tolerance_content, old_string) do
                [{offset, len}] ->
                  before_char_len =
                    if search_start > 0 do
                      (Enum.take(file_lines, search_start) |> Enum.join(sep) |> String.length()) + String.length(sep)
                    else
                      0
                    end
                  {:ok, :exact_tolerance, before_char_len + offset, len}

                _ -> :none
              end
            else
              :none
            end
          end

        true ->
          :none
      end

    case exact_match do
      {:ok, _type, offset, len} ->
        # We found a unique exact match! Apply it
        apply_exact_replacement(expanded_path, content, offset, len, new_string, dry_run)

      {:error, :ambiguous, line_numbers} ->
        "Error: old_string is ambiguous. It occurs #{length(line_numbers)} times in the file at lines: #{Enum.join(line_numbers, ", ")}."

      :none ->
        # 3. Try Whitespace-Normalized Line Match
        old_lines = String.split(old_string, ~r/\r?\n/)
        
        # Priority 1: Normalized match in exact range
        norm_matches = find_normalized_matches(file_lines, old_lines, start_idx, end_idx)

        # Priority 2: Normalized match in expanded/tolerance range
        {norm_matches, _type} =
          if norm_matches == [] and has_range do
            {find_normalized_matches(file_lines, old_lines, search_start, search_end), :normalized_tolerance}
          else
            {norm_matches, :normalized}
          end

        case norm_matches do
          [matched_idx] ->
            # Unique normalized match found! Apply with indentation adaptation
            apply_normalized_replacement(
              expanded_path,
              file_lines,
              matched_idx,
              old_lines,
              new_string,
              sep,
              dry_run
            )

          matches when length(matches) > 1 ->
            # Ambiguous normalized matches
            line_numbers = Enum.map(matches, &(&1 + 1))
            "Error: old_string is ambiguous under whitespace-normalized matching. It matches #{length(line_numbers)} times starting at lines: #{Enum.join(line_numbers, ", ")}."

          [] ->
            # 4. Not found at all - generate smart diagnostic preview & fuzzy hint
            report_not_found_error(file_lines, old_lines, start_line, end_line, sep)
        end
    end
  end

  defp apply_exact_replacement(expanded_path, content, offset, len, new_string, dry_run) do
    before_part = String.slice(content, 0, offset)
    after_part = String.slice(content, offset + len, String.length(content))
    new_content = before_part <> new_string <> after_part

    if dry_run do
      "Dry-run succeeded: #{expanded_path} would be updated."
    else
      case File.write(expanded_path, new_content) do
        :ok -> "Successfully updated #{expanded_path}"
        {:error, reason} -> "Error writing file #{expanded_path}: #{reason}"
      end
    end
  end

  defp apply_normalized_replacement(expanded_path, file_lines, matched_idx, old_lines, new_string, sep, dry_run) do
    k = length(old_lines)
    file_matched_lines = Enum.slice(file_lines, matched_idx, k)
    new_lines = String.split(new_string, ~r/\r?\n/)
    adjusted_new_lines = adjust_indent(new_lines, old_lines, file_matched_lines)

    before_lines = Enum.take(file_lines, matched_idx)
    after_lines = Enum.drop(file_lines, matched_idx + k)
    new_file_lines = before_lines ++ adjusted_new_lines ++ after_lines
    new_content = Enum.join(new_file_lines, sep)

    if dry_run do
      "Dry-run succeeded: #{expanded_path} would be updated."
    else
      case File.write(expanded_path, new_content) do
        :ok -> "Successfully updated #{expanded_path}"
        {:error, reason} -> "Error writing file #{expanded_path}: #{reason}"
      end
    end
  end

  defp find_normalized_matches(file_lines, old_lines, start_idx, end_idx) do
    norm_old = Enum.map(old_lines, &normalize_line/1)
    norm_file = Enum.map(file_lines, &normalize_line/1)
    k = length(old_lines)
    limit = end_idx - k + 1

    if limit >= start_idx do
      Enum.reduce(start_idx..limit, [], fn i, acc ->
        sub = Enum.slice(norm_file, i, k)
        if sub == norm_old do
          [i | acc]
        else
          acc
        end
      end)
      |> :lists.reverse()
    else
      []
    end
  end

  defp adjust_indent(new_lines, old_lines, file_matched_lines) do
    old_first = List.first(old_lines) || ""
    file_first = List.first(file_matched_lines) || ""
    old_indent = get_indent(old_first)
    file_indent = get_indent(file_first)

    cond do
      old_indent == file_indent ->
        new_lines

      old_indent == "" ->
        Enum.map(new_lines, fn
          "" -> ""
          line -> file_indent <> line
        end)

      true ->
        old_len = String.length(old_indent)
        file_len = String.length(file_indent)
        diff = file_len - old_len

        if diff > 0 do
          indent_to_add = String.duplicate(String.slice(file_indent, 0, 1), diff)

          Enum.map(new_lines, fn
            "" -> ""
            line -> indent_to_add <> line
          end)
        else
          new_lines
        end
    end
  end

  defp get_indent(line) do
    case Regex.run(~r/^[ \t]*/, line) do
      [indent] -> indent
      _ -> ""
    end
  end

  defp normalize_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/[ \t]+/, " ")
  end

  defp detect_line_ending(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  defp find_all_occurrences_lines(content, old_string, sep) do
    case :binary.matches(content, old_string) do
      [] ->
        []

      matches ->
        Enum.map(matches, fn {offset, _len} ->
          before_substring = String.slice(content, 0, offset)
          length(String.split(before_substring, sep))
        end)
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
            sub
            |> Enum.zip(old_lines)
            |> Enum.map(fn {fl, ol} -> String.jaro_distance(fl, ol) end)
            |> Enum.sum()
            |> Kernel./(k)

          if sim > best_s do
            {i, sim}
          else
            {best_i, best_s}
          end
        end)

      if best_sim > 0.5 do
        {:ok, best_idx, k, best_sim}
      else
        :error
      end
    else
      :error
    end
  end

  defp report_not_found_error(file_lines, old_lines, start_line, end_line, _sep) do
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
            prefix = if num >= (best_idx + 1) and num <= (best_idx + k), do: "=> #{num}: ", else: "   #{num}: "
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
end
