defmodule Beamcore.Agent.Tools.Modify do
  @moduledoc """
  Deterministic, workspace-bounded file modification tool.
  """

  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.PathSafety

  @description """
  Modify one workspace file using an explicit, verified operation.

  Supported operations:
  - replace_exact: replace exact text, failing on missing or ambiguous matches.
  - insert_before / insert_after: insert content at an exact anchor.
  - replace_range: replace 1-based inclusive line range.
  - create_file: create a new file, or overwrite only with overwrite=true.
  """

  @diff_context 3
  @max_diff_bytes 8_000

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
            operation: %{
              type: "string",
              enum: [
                "replace_exact",
                "insert_before",
                "insert_after",
                "replace_range",
                "create_file"
              ],
              description:
                "Explicit modification operation. Read the file first and provide exact text."
            },
            path: %{
              type: "string",
              description: "Workspace-relative file path."
            },
            old: %{
              type: "string",
              description: "Exact text to replace for replace_exact."
            },
            new: %{
              type: "string",
              description: "Replacement text for replace_exact."
            },
            anchor: %{
              type: "string",
              description: "Exact anchor text for insert_before or insert_after."
            },
            content: %{
              type: "string",
              description: "Inserted, range replacement, or new file content."
            },
            occurrence: %{
              oneOf: [%{type: "string", enum: ["only"]}, %{type: "integer", minimum: 1}],
              description:
                "Match occurrence. Defaults to only; use a positive integer for explicit duplicates."
            },
            start_line: %{
              type: "integer",
              minimum: 1,
              description: "1-based inclusive start line for replace_range."
            },
            end_line: %{
              type: "integer",
              minimum: 1,
              description: "1-based inclusive end line for replace_range."
            },
            overwrite: %{
              type: "boolean",
              description: "For create_file only. Existing files are replaced only when true."
            },
            expected_sha256: %{
              type: "string",
              description: "Optional optimistic concurrency guard for the current file bytes."
            },
            dry_run: %{
              type: "boolean",
              description: "Validate and return the planned result without writing."
            }
          },
          required: ["operation", "path"]
        }
      }
    }
  end

  def execute(params) when is_map(params) do
    params
    |> normalize_params()
    |> run()
    |> Jason.encode!()
  rescue
    error ->
      error_result(
        Map.get(params, "operation", "unknown"),
        Map.get(params, "path", ""),
        "unexpected modify_file failure: #{Exception.message(error)}"
      )
      |> Jason.encode!()
  end

  def execute(_params) do
    error_result("unknown", "", "parameters must be an object") |> Jason.encode!()
  end

  defp normalize_params(params) do
    %{
      operation: Map.get(params, "operation"),
      path: Map.get(params, "path") || Map.get(params, "filePath"),
      old: Map.get(params, "old"),
      new: Map.get(params, "new"),
      anchor: Map.get(params, "anchor"),
      content: Map.get(params, "content"),
      occurrence: Map.get(params, "occurrence", "only"),
      start_line: Map.get(params, "start_line"),
      end_line: Map.get(params, "end_line"),
      overwrite: Map.get(params, "overwrite", false),
      expected_sha256: Map.get(params, "expected_sha256"),
      dry_run: Map.get(params, "dry_run", false)
    }
  end

  defp run(%{operation: operation, path: path} = params) do
    with :ok <- validate_operation(operation),
         :ok <- validate_path_param(path),
         :ok <- ProjectPolicy.allowed_write_path?(path),
         {:ok, safe_path} <- PathSafety.resolve(path, allow_missing: operation == "create_file"),
         {:ok, original} <- load_original(safe_path, operation),
         :ok <- validate_expected_sha256(original, params.expected_sha256),
         {:ok, plan} <- build_plan(params, safe_path, original),
         :ok <- validate_changed(plan),
         :ok <- verify_plan(plan) do
      maybe_write(plan, params.dry_run)
    else
      {:error, reason} -> error_result(operation || "unknown", path || "", reason)
    end
  end

  defp validate_operation(operation)
       when operation in [
              "replace_exact",
              "insert_before",
              "insert_after",
              "replace_range",
              "create_file"
            ],
       do: :ok

  defp validate_operation(nil), do: {:error, "operation is required"}
  defp validate_operation(operation), do: {:error, "unsupported operation: #{inspect(operation)}"}

  defp validate_path_param(path) when is_binary(path) and path != "", do: :ok
  defp validate_path_param(_path), do: {:error, "path is required"}

  defp load_original(path, "create_file") do
    cond do
      File.dir?(path) ->
        {:error, "target is a directory: #{Path.relative_to(path, PathSafety.workspace_root())}"}

      File.exists?(path) ->
        read_existing_text(path)

      true ->
        {:ok, nil}
    end
  end

  defp load_original(path, _operation), do: read_existing_text(path)

  defp read_existing_text(path) do
    cond do
      File.dir?(path) ->
        {:error, "target is a directory: #{Path.relative_to(path, PathSafety.workspace_root())}"}

      not File.exists?(path) ->
        {:error, "file does not exist: #{Path.relative_to(path, PathSafety.workspace_root())}"}

      true ->
        case File.read(path) do
          {:ok, bytes} -> validate_text(bytes)
          {:error, reason} -> {:error, "cannot read file: #{reason}"}
        end
    end
  end

  defp validate_text(bytes) do
    cond do
      :binary.match(bytes, <<0>>) != :nomatch ->
        {:error, "binary files are not supported"}

      not String.valid?(bytes) ->
        {:error, "file is not valid UTF-8 text"}

      true ->
        {:ok, bytes}
    end
  end

  defp validate_expected_sha256(_original, nil), do: :ok
  defp validate_expected_sha256(_original, ""), do: :ok

  defp validate_expected_sha256(nil, _expected),
    do: {:error, "expected_sha256 was provided but the target file does not exist"}

  defp validate_expected_sha256(original, expected) do
    actual = sha256(original)

    if actual == expected do
      :ok
    else
      {:error, "checksum mismatch: expected #{expected}, current #{actual}"}
    end
  end

  defp build_plan(%{operation: "create_file"} = params, path, original) do
    with {:ok, content} <- required_string(params.content, "content"),
         :ok <- validate_create_overwrite(original, params.overwrite) do
      plan(params, path, original, content, 0)
    end
  end

  defp build_plan(%{operation: "replace_exact"} = params, path, original) do
    with {:ok, old} <- required_non_empty(params.old, "old"),
         {:ok, new} <- required_string(params.new, "new"),
         {:ok, match} <- resolve_occurrence(original, old, params.occurrence) do
      {offset, length} = match.selected
      content = binary_replace_at(original, offset, length, new)
      plan(params, path, original, content, match.count)
    end
  end

  defp build_plan(%{operation: operation} = params, path, original)
       when operation in ["insert_before", "insert_after"] do
    with {:ok, anchor} <- required_non_empty(params.anchor, "anchor"),
         {:ok, content} <- required_string(params.content, "content"),
         {:ok, match} <- resolve_occurrence(original, anchor, params.occurrence) do
      {offset, length} = match.selected
      insert_at = if operation == "insert_before", do: offset, else: offset + length
      new_content = binary_insert_at(original, insert_at, content)
      plan(params, path, original, new_content, match.count)
    end
  end

  defp build_plan(%{operation: "replace_range"} = params, path, original) do
    with {:ok, start_line} <- positive_integer(params.start_line, "start_line"),
         {:ok, end_line} <- positive_integer(params.end_line, "end_line"),
         {:ok, content} <- required_string(params.content, "content"),
         {:ok, new_content} <- replace_line_range(original, start_line, end_line, content) do
      plan(params, path, original, new_content, end_line - start_line + 1)
    end
  end

  defp validate_create_overwrite(nil, _overwrite), do: :ok
  defp validate_create_overwrite(_original, true), do: :ok

  defp validate_create_overwrite(_original, _overwrite),
    do: {:error, "file already exists; set overwrite=true to replace it"}

  defp required_string(value, _field) when is_binary(value), do: {:ok, value}
  defp required_string(_value, field), do: {:error, "#{field} must be a string"}

  defp required_non_empty(value, field) when is_binary(value) do
    if value == "", do: {:error, "#{field} must not be empty"}, else: {:ok, value}
  end

  defp required_non_empty(_value, field), do: {:error, "#{field} must be a non-empty string"}

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, "#{field} must be a positive integer"}
    end
  end

  defp positive_integer(_value, field), do: {:error, "#{field} must be a positive integer"}

  defp resolve_occurrence(content, needle, occurrence) do
    matches = :binary.matches(content, needle)
    count = length(matches)

    cond do
      count == 0 ->
        {:error, "target text not found"}

      occurrence in [nil, "only"] and count == 1 ->
        {:ok, %{selected: hd(matches), count: count}}

      occurrence in [nil, "only"] ->
        {:error, "target text is ambiguous: #{count} occurrences found"}

      true ->
        with {:ok, index} <- positive_integer(occurrence, "occurrence") do
          if index <= count do
            {:ok, %{selected: Enum.at(matches, index - 1), count: count}}
          else
            {:error, "occurrence #{index} is out of range; #{count} occurrences found"}
          end
        end
    end
  end

  defp replace_line_range(content, start_line, end_line, replacement) do
    line_ending = detect_line_ending(content)
    lines = split_logical_lines(content)
    line_count = logical_line_count(lines)

    cond do
      start_line > end_line ->
        {:error, "start_line must be less than or equal to end_line"}

      line_count == 0 ->
        {:error, "cannot replace a line range in an empty file"}

      start_line > line_count or end_line > line_count ->
        {:error, "line range #{start_line}-#{end_line} is outside file with #{line_count} lines"}

      true ->
        replacement_lines = replacement |> trim_one_trailing_newline() |> split_logical_lines()
        before_lines = Enum.slice(lines, 0, start_line - 1)
        after_lines = Enum.slice(lines, end_line, length(lines) - end_line)
        {:ok, Enum.join(before_lines ++ replacement_lines ++ after_lines, line_ending)}
    end
  end

  defp split_logical_lines(""), do: []
  defp split_logical_lines(content), do: Regex.split(~r/\r\n|\n|\r/, content, trim: false)

  defp logical_line_count([]), do: 0

  defp logical_line_count(lines) do
    if List.last(lines) == "", do: length(lines) - 1, else: length(lines)
  end

  defp trim_one_trailing_newline(content) do
    cond do
      String.ends_with?(content, "\r\n") -> String.slice(content, 0, byte_size(content) - 2)
      String.ends_with?(content, "\n") -> String.slice(content, 0, byte_size(content) - 1)
      String.ends_with?(content, "\r") -> String.slice(content, 0, byte_size(content) - 1)
      true -> content
    end
  end

  defp plan(params, path, original, content, matched_count) do
    relative_path = Path.relative_to(path, PathSafety.workspace_root())
    original_content = original || ""

    {:ok,
     %{
       operation: params.operation,
       path: path,
       relative_path: relative_path,
       original: original_content,
       content: content,
       existed?: not is_nil(original),
       matched_count: matched_count,
       bytes_before: byte_size(original_content),
       bytes_after: byte_size(content),
       sha256_before: sha256(original_content),
       sha256_after: sha256(content),
       dry_run: params.dry_run
     }}
  end

  defp validate_changed(%{existed?: false}), do: :ok

  defp validate_changed(%{original: original, content: content}) do
    if original == content do
      {:error, "operation would not change the file"}
    else
      :ok
    end
  end

  defp verify_plan(%{content: content}) do
    case validate_text(content) do
      {:ok, _content} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_write(plan, true),
    do: success_result(plan, "Dry-run succeeded; file would be modified.")

  defp maybe_write(plan, false) do
    with :ok <- File.mkdir_p(Path.dirname(plan.path)),
         :ok <- atomic_write(plan.path, plan.content),
         {:ok, reread} <- File.read(plan.path),
         :ok <- verify_written_content(plan, reread) do
      success_result(plan, "File modified successfully.")
    else
      {:error, reason} ->
        restore_original(plan)

        error_result(
          plan.operation,
          plan.relative_path,
          "write verification failed: #{reason}",
          plan
        )
    end
  end

  defp verify_written_content(plan, reread) do
    cond do
      reread != plan.content ->
        {:error, "reread content does not match planned content"}

      sha256(reread) != plan.sha256_after ->
        {:error, "reread checksum does not match planned checksum"}

      true ->
        :ok
    end
  end

  defp restore_original(%{operation: "create_file", existed?: false, path: path}) do
    File.rm(path)
    :ok
  end

  defp restore_original(%{path: path, original: original}) do
    File.write(path, original)
    :ok
  end

  defp atomic_write(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp.#{System.unique_integer([:positive])}"
      )

    try do
      with :ok <- File.write(tmp, content),
           :ok <- File.rename(tmp, path) do
        :ok
      end
    after
      File.rm(tmp)
    end
  end

  defp success_result(plan, summary) do
    %{
      "ok" => true,
      "changed" => true,
      "operation" => plan.operation,
      "path" => plan.relative_path,
      "summary" => summary,
      "bytes_before" => plan.bytes_before,
      "bytes_after" => plan.bytes_after,
      "sha256_before" => plan.sha256_before,
      "sha256_after" => plan.sha256_after,
      "matched_occurrences" => plan.matched_count,
      "diff" => compact_diff(plan.relative_path, plan.original, plan.content)
    }
  end

  defp error_result(operation, path, reason, plan \\ nil) do
    result = %{
      "ok" => false,
      "changed" => false,
      "operation" => operation,
      "path" => path,
      "summary" => reason
    }

    if plan do
      Map.merge(result, %{
        "bytes_before" => plan.bytes_before,
        "bytes_after" => plan.bytes_before,
        "sha256_before" => plan.sha256_before,
        "sha256_after" => plan.sha256_before,
        "matched_occurrences" => plan.matched_count
      })
    else
      result
    end
  end

  defp binary_replace_at(content, offset, length, replacement) do
    binary_part(content, 0, offset) <>
      replacement <> binary_part(content, offset + length, byte_size(content) - offset - length)
  end

  defp binary_insert_at(content, offset, insertion) do
    binary_part(content, 0, offset) <>
      insertion <> binary_part(content, offset, byte_size(content) - offset)
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp detect_line_ending(content) do
    cond do
      :binary.match(content, "\r\n") != :nomatch -> "\r\n"
      :binary.match(content, "\r") != :nomatch -> "\r"
      true -> "\n"
    end
  end

  defp compact_diff(path, old_content, new_content) do
    old_lines = String.split(old_content, "\n", trim: false)
    new_lines = String.split(new_content, "\n", trim: false)

    case first_difference(old_lines, new_lines) do
      nil ->
        ""

      first ->
        old_last = last_changed_index(old_lines, new_lines)
        new_last = last_changed_index(new_lines, old_lines)
        old_start = max(first - @diff_context, 0)
        new_start = max(first - @diff_context, 0)
        old_stop = min(old_last + @diff_context, length(old_lines) - 1)
        new_stop = min(new_last + @diff_context, length(new_lines) - 1)

        [
          "--- a/#{path}",
          "+++ b/#{path}",
          "@@ -#{old_start + 1},#{old_stop - old_start + 1} +#{new_start + 1},#{new_stop - new_start + 1} @@"
          | diff_lines(old_lines, new_lines, old_start, old_stop, new_start, new_stop)
        ]
        |> Enum.join("\n")
        |> truncate_diff()
    end
  end

  defp first_difference(old_lines, new_lines) do
    max_len = max(length(old_lines), length(new_lines))

    Enum.find(0..max(max_len - 1, 0), fn index ->
      Enum.at(old_lines, index) != Enum.at(new_lines, index)
    end)
  end

  defp last_changed_index(lines, other_lines) do
    max_len = max(length(lines), length(other_lines))

    Enum.find(max(max_len - 1, 0)..0//-1, 0, fn index ->
      Enum.at(lines, index) != Enum.at(other_lines, index)
    end)
  end

  defp diff_lines(old_lines, new_lines, old_start, old_stop, new_start, new_stop) do
    old_window = Enum.slice(old_lines, old_start, old_stop - old_start + 1)
    new_window = Enum.slice(new_lines, new_start, new_stop - new_start + 1)

    common_prefix =
      old_window
      |> Enum.zip(new_window)
      |> Enum.take_while(fn {old, new} -> old == new end)
      |> Enum.map(fn {line, _} -> " " <> line end)

    removed = Enum.drop(old_window, length(common_prefix)) |> Enum.map(&("-" <> &1))
    added = Enum.drop(new_window, length(common_prefix)) |> Enum.map(&("+" <> &1))
    common_prefix ++ removed ++ added
  end

  defp truncate_diff(diff) do
    if byte_size(diff) > @max_diff_bytes do
      String.slice(diff, 0, @max_diff_bytes) <> "\n... (diff truncated)"
    else
      diff
    end
  end
end
