defmodule Beamcore.Agent.Tools.Edit do
  @moduledoc """
  Tool to replace exact string in a file with state-of-the-art matching, line-range,
  and whitespace tolerance.
  """
  alias Beamcore.Agent.Policy.ProjectPolicy
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
                "Optional. One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits.",
              items: %{
                type: "object",
                properties: %{
                  old_string: %{
                    type: "string",
                    description: "The exact literal text to replace."
                  },
                  new_string: %{
                    type: "string",
                    description: "The exact literal text to replace it with."
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
      # Alignment Interception Guard Layer (First brick)
      agent_name = Map.get(params, "agent_name") || Map.get(params, "agent") || System.get_env("AGENT_NAME") || "agent_default"
      
      file_hash =
        case File.read(expanded_path) do
          {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
          _ -> ""
        end

      case Beamcore.Alignment.claim_file(expanded_path, agent_name, file_hash) do
        {:conflict, score, other_agent} when score >= 80 ->
          "Error: Alignment Conflict. Another agent '#{other_agent}' is actively working on #{path} (Conflict Score: #{score})."

        _ ->
          # Run under mutation lock!
          case Beamcore.Agent.Tools.FileMutationQueue.with_lock(expanded_path, 5000, fn ->
                 case File.read(expanded_path) do
                   {:ok, content} ->
                     process_edit(
                       expanded_path,
                       content,
                       params,
                       dry_run
                     )

                   {:error, reason} ->
                     "Error reading file #{expanded_path}: #{reason}"
                 end
               end) do
            {:error, :lock_timeout} ->
              "Error: Could not acquire lock to modify file #{expanded_path} (timeout after 5s)."

            result ->
              result
          end
      end
    else
      {:error, reason} ->
        PathSafety.error(reason)
    end
  end

  defp process_edit(expanded_path, content, params, dry_run) do
    # 1. Strip BOM
    {has_bom?, content_without_bom} = strip_bom(content)

    # 2. Detect line ending
    sep = detect_line_ending(content_without_bom)

    # 3. Normalize original content to LF
    normalized_content = normalize_to_lf(content_without_bom)

    # 4. Parse edits
    edits = parse_edits(params)

    # 5. Extract single-edit parameters if applicable
    {start_line, end_line} =
      if length(edits) == 1 do
        {Map.get(params, "start_line"), Map.get(params, "end_line")}
      else
        {nil, nil}
      end

    # 6. Apply edits to normalized content
    try do
      {_base_content, new_content} =
        apply_edits_to_normalized_content(
          normalized_content,
          edits,
          expanded_path,
          start_line,
          end_line
        )

      # 7. Restore line endings and prepend BOM
      final_new_content =
        new_content
        |> restore_line_endings(sep)
        |> then(fn text -> if has_bom?, do: "\uFEFF" <> text, else: text end)

      # 8. Generate diff
      diff =
        generate_diff(params["path"] || Path.basename(expanded_path), content, final_new_content)

      if dry_run do
        "Dry-run succeeded: #{expanded_path} would be updated." <>
          if(diff != "", do: "\n\n" <> diff, else: "")
      else
        case File.write(expanded_path, final_new_content) do
          :ok ->
            "Successfully updated #{expanded_path}" <>
              if(diff != "", do: "\n\n" <> diff, else: "")

          {:error, reason} ->
            "Error writing file #{expanded_path}: #{reason}"
        end
      end
    catch
      {:error, :empty_old_string} ->
        "Error: old_string must not be empty."

      {:error, {:not_found, idx, old_string}} ->
        if length(edits) == 1 do
          file_lines = String.split(normalized_content, "\n")
          old_lines = String.split(old_string, "\n")
          report_not_found_error(file_lines, old_lines, start_line, end_line, sep)
        else
          "Error: Could not find edits[#{idx}] in #{expanded_path}. The oldText must match exactly including all whitespace and newlines."
        end

      {:error, {:ambiguous, idx, _old_string, line_numbers}} ->
        if length(edits) == 1 do
          "Error: old_string is ambiguous. It occurs #{length(line_numbers)} times in the file at lines: #{Enum.join(line_numbers, ", ")}."
        else
          "Error: Found #{length(line_numbers)} occurrences of edits[#{idx}] in #{expanded_path}. Each oldText must be unique. Please provide more context to make it unique."
        end

      {:error, {:overlap, prev_idx, curr_idx}} ->
        "Error: edits[#{prev_idx}] and edits[#{curr_idx}] overlap in #{expanded_path}. Merge them into one edit or target disjoint regions."

      {:error, :no_change} ->
        if length(edits) == 1 do
          "Error: No changes would be made to the file."
        else
          "Error: No changes made to #{expanded_path}. The replacements produced identical content."
        end
    end
  end

  # Helper Functions

  defp strip_bom(content) do
    if String.starts_with?(content, "\uFEFF") do
      {true, String.slice(content, 1..-1//1)}
    else
      {false, content}
    end
  end

  defp detect_line_ending(content) do
    crlf_idx =
      case :binary.match(content, "\r\n") do
        {idx, _} -> idx
        :nomatch -> nil
      end

    lf_idx =
      case :binary.match(content, "\n") do
        {idx, _} -> idx
        :nomatch -> nil
      end

    cond do
      is_nil(lf_idx) -> "\n"
      is_nil(crlf_idx) -> "\n"
      crlf_idx < lf_idx -> "\r\n"
      true -> "\n"
    end
  end

  defp normalize_to_lf(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp restore_line_endings(text, "\r\n") do
    String.replace(text, "\n", "\r\n")
  end

  defp restore_line_endings(text, _), do: text

  defp parse_edits(params) do
    edits_param = Map.get(params, "edits")

    edits_list =
      cond do
        is_binary(edits_param) ->
          case Jason.decode(edits_param) do
            {:ok, decoded} when is_list(decoded) -> decoded
            _ -> nil
          end

        is_list(edits_param) ->
          edits_param

        true ->
          nil
      end

    if edits_list do
      Enum.map(edits_list, fn edit ->
        old =
          Map.get(edit, "old_string") || Map.get(edit, "oldText") ||
            Map.fetch!(edit, "old_string")

        new =
          Map.get(edit, "new_string") || Map.get(edit, "newText") ||
            Map.fetch!(edit, "new_string")

        %{
          old_string: sanitize_obfuscated_emails(old),
          new_string: sanitize_obfuscated_emails(new)
        }
      end)
    else
      old_string = Map.fetch!(params, "old_string") |> sanitize_obfuscated_emails()
      new_string = Map.fetch!(params, "new_string") |> sanitize_obfuscated_emails()
      [%{old_string: old_string, new_string: new_string}]
    end
  end

  defp normalize_for_fuzzy_match(text) do
    text
    |> String.normalize(:nfkc)
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.replace(~r/[\x{2018}\x{2019}\x{201A}\x{201B}]/u, "'")
    |> String.replace(~r/[\x{201C}\x{201D}\x{201E}\x{201F}]/u, "\"")
    |> String.replace(~r/[\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]/u, "-")
    |> String.replace(~r/[\x{00A0}\x{2002}-\x{200A}\x{202F}\x{205F}\x{3000}]/u, " ")
  end

  defp fuzzy_find_text(content, old_text) do
    case :binary.match(content, old_text) do
      {exact_index, len} ->
        %{
          found: true,
          index: exact_index,
          match_length: len,
          used_fuzzy_match: false,
          content_for_replacement: content
        }

      :nomatch ->
        fuzzy_content = normalize_for_fuzzy_match(content)
        fuzzy_old_text = normalize_for_fuzzy_match(old_text)

        case :binary.match(fuzzy_content, fuzzy_old_text) do
          {fuzzy_index, len} ->
            %{
              found: true,
              index: fuzzy_index,
              match_length: len,
              used_fuzzy_match: true,
              content_for_replacement: fuzzy_content
            }

          :nomatch ->
            %{
              found: false,
              index: -1,
              match_length: 0,
              used_fuzzy_match: false,
              content_for_replacement: content
            }
        end
    end
  end

  defp find_edit_match(base_content, old_text, start_line, end_line) do
    matches = :binary.matches(base_content, old_text)
    has_range = not is_nil(start_line) or not is_nil(end_line)

    cond do
      matches == [] ->
        {:error, :not_found}

      not has_range ->
        case matches do
          [{index, length}] ->
            {:ok, index, length}

          _ ->
            {:error, :ambiguous, Enum.map(matches, &elem(&1, 0))}
        end

      has_range ->
        {exact_start, exact_end, _start_idx, _end_idx} =
          line_range_to_offsets(base_content, start_line, end_line)

        exact_matches =
          Enum.filter(matches, fn {idx, len} -> idx >= exact_start and idx + len <= exact_end end)

        case exact_matches do
          [{index, length}] ->
            {:ok, index, length}

          [] ->
            tol_start_line = if start_line, do: max(1, start_line - 20), else: nil
            tol_end_line = if end_line, do: end_line + 20, else: nil

            {tol_start, tol_end, _start_idx, _end_idx} =
              line_range_to_offsets(base_content, tol_start_line, tol_end_line)

            tol_matches =
              Enum.filter(matches, fn {idx, len} -> idx >= tol_start and idx + len <= tol_end end)

            case tol_matches do
              [{index, length}] ->
                {:ok, index, length}

              [] ->
                {:error, :not_found}

              _ ->
                {:error, :ambiguous, Enum.map(tol_matches, &elem(&1, 0))}
            end

          _ ->
            {:error, :ambiguous, Enum.map(exact_matches, &elem(&1, 0))}
        end
    end
  end

  defp line_range_to_offsets(normalized_content, start_line, end_line) do
    lines = String.split(normalized_content, "\n")
    total_lines = length(lines)

    start_idx = if start_line, do: max(0, min(start_line - 1, total_lines - 1)), else: 0

    end_idx =
      if end_line, do: max(start_idx, min(end_line - 1, total_lines - 1)), else: total_lines - 1

    start_offset =
      if start_idx > 0 do
        (Enum.take(lines, start_idx) |> Enum.join("\n") |> String.length()) + 1
      else
        0
      end

    end_offset =
      Enum.take(lines, end_idx + 1) |> Enum.join("\n") |> String.length()

    {start_offset, end_offset, start_idx, end_idx}
  end

  defp get_line_number_for_offset(content, offset) do
    before_substring = String.slice(content, 0, offset)
    length(String.split(before_substring, "\n"))
  end

  defp find_all_occurrences_lines(content, matches) do
    Enum.map(matches, fn idx ->
      get_line_number_for_offset(content, idx)
    end)
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
        {diff_out, _status} ->
          diff_out
      end
    rescue
      _ ->
        ""
    after
      File.rm(tmp_old)
      File.rm(tmp_new)
    end
  end

  defp apply_edits_to_normalized_content(normalized_content, edits, _path, start_line, end_line) do
    normalized_edits =
      Enum.map(edits, fn edit ->
        old_normalized = normalize_to_lf(edit.old_string)
        new_normalized = normalize_to_lf(edit.new_string)

        %{
          old_string: old_normalized,
          new_string: align_newlines(old_normalized, new_normalized)
        }
      end)

    Enum.each(normalized_edits, fn edit ->
      if edit.old_string == "" do
        throw({:error, :empty_old_string})
      end
    end)

    any_fuzzy? =
      Enum.any?(normalized_edits, fn edit ->
        match_result = fuzzy_find_text(normalized_content, edit.old_string)
        match_result.used_fuzzy_match
      end)

    base_content =
      if any_fuzzy? do
        normalize_for_fuzzy_match(normalized_content)
      else
        normalized_content
      end

    matched_edits =
      normalized_edits
      |> Enum.with_index()
      |> Enum.map(fn {edit, idx} ->
        case find_edit_match(base_content, edit.old_string, start_line, end_line) do
          {:ok, index, length} ->
            %{
              edit_index: idx,
              match_index: index,
              match_length: length,
              new_string: edit.new_string
            }

          {:error, :not_found} ->
            throw({:error, {:not_found, idx, edit.old_string}})

          {:error, :ambiguous, match_indices} ->
            line_numbers = find_all_occurrences_lines(base_content, match_indices)
            throw({:error, {:ambiguous, idx, edit.old_string, line_numbers}})
        end
      end)

    sorted_matched_edits = Enum.sort_by(matched_edits, & &1.match_index)

    if length(sorted_matched_edits) > 1 do
      Enum.reduce(sorted_matched_edits, nil, fn
        current, nil ->
          current

        current, previous ->
          if previous.match_index + previous.match_length > current.match_index do
            throw({:error, {:overlap, previous.edit_index, current.edit_index}})
          else
            current
          end
      end)
    end

    new_content =
      Enum.reduce(Enum.reverse(sorted_matched_edits), base_content, fn edit, acc ->
        before_part = String.slice(acc, 0, edit.match_index)
        after_part = String.slice(acc, (edit.match_index + edit.match_length)..-1//1)
        before_part <> edit.new_string <> after_part
      end)

    if base_content == new_content do
      throw({:error, :no_change})
    end

    {base_content, new_content}
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

  defp align_newlines(old_string, new_string) do
    new_string
    |> then(&align_leading_newlines(old_string, &1))
    |> then(&align_trailing_newlines(old_string, &1))
  end

  defp count_leading_newlines(binary) when is_binary(binary) do
    count_leading_newlines_byte(binary, 0, byte_size(binary), 0)
  end

  defp count_leading_newlines_byte(_binary, len, len, acc), do: acc
  defp count_leading_newlines_byte(binary, index, len, acc) do
    case :binary.at(binary, index) do
      10 -> count_leading_newlines_byte(binary, index + 1, len, acc + 1)
      _ -> acc
    end
  end

  defp align_leading_newlines(old_string, new_string) do
    if new_string == "" do
      new_string
    else
      old_newlines = count_leading_newlines(old_string)
      new_newlines = count_leading_newlines(new_string)

      if old_newlines > new_newlines do
        String.duplicate("\n", old_newlines - new_newlines) <> new_string
      else
        new_string
      end
    end
  end

  defp count_trailing_newlines(binary) when is_binary(binary) do
    count_trailing_newlines_byte(binary, byte_size(binary) - 1, 0)
  end

  defp count_trailing_newlines_byte(_binary, -1, acc), do: acc
  defp count_trailing_newlines_byte(binary, index, acc) do
    case :binary.at(binary, index) do
      10 -> count_trailing_newlines_byte(binary, index - 1, acc + 1)
      _ -> acc
    end
  end

  defp align_trailing_newlines(old_string, new_string) do
    if new_string == "" do
      new_string
    else
      old_newlines = count_trailing_newlines(old_string)
      new_newlines = count_trailing_newlines(new_string)

      if old_newlines > new_newlines do
        new_string <> String.duplicate("\n", old_newlines - new_newlines)
      else
        new_string
      end
    end
  end

  defp sanitize_obfuscated_emails(content) when is_binary(content) do
    String.replace(content, ~r/\[email[\s\x{00A0}]*protected\]/iu, "$@")
  end
end
