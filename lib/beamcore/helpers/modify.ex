defmodule Beamcore.Helpers.Modify do
  @moduledoc """
  Line-aware editing helpers intended for Eeva programs.

  This module is not a model-facing tool. It gives model-authored Elixir a
  precise way to inspect numbered lines and apply bounded edits while reusing
  Eeva's runtime policy checks for the actual file reads and writes.
  """

  alias Beamcore.Agent.Tools.Eeva.Policy

  @doc "Returns numbered lines from a UTF-8 text file."
  def lines(path, first \\ 1, last \\ :all)
      when is_binary(path) and is_integer(first) and first >= 1 do
    content = Policy.file(:read!, [path])
    split = String.split(content, "\n", trim: false)
    final = if last == :all, do: length(split), else: last

    split
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, number} -> number >= first and number <= final end)
  end

  @doc "Replaces an inclusive one-based line range and returns edit metadata."
  def replace_range(path, first, last, replacement)
      when is_binary(path) and is_integer(first) and is_integer(last) and first >= 1 and
             last >= first and is_binary(replacement) do
    update(
      path,
      fn lines ->
        validate_range!(lines, first, last)
        replacement_lines = String.split(replacement, "\n", trim: false)
        prefix = Enum.take(lines, first - 1)
        suffix = Enum.drop(lines, last)
        prefix ++ replacement_lines ++ suffix
      end,
      %{operation: :replace_range, first: first, last: last}
    )
  end

  @doc "Inserts text after a one-based line number. Use zero to insert at the start."
  def insert_after(path, line_number, content)
      when is_binary(path) and is_integer(line_number) and line_number >= 0 and
             is_binary(content) do
    update(
      path,
      fn lines ->
        if line_number > length(lines) do
          raise ArgumentError, "line #{line_number} is outside #{path}"
        end

        {head, tail} = Enum.split(lines, line_number)
        head ++ String.split(content, "\n", trim: false) ++ tail
      end,
      %{operation: :insert_after, line: line_number}
    )
  end

  @doc "Deletes an inclusive one-based line range."
  def delete_range(path, first, last)
      when is_binary(path) and is_integer(first) and is_integer(last) and first >= 1 and
             last >= first do
    update(
      path,
      fn lines ->
        validate_range!(lines, first, last)
        Enum.take(lines, first - 1) ++ Enum.drop(lines, last)
      end,
      %{operation: :delete_range, first: first, last: last}
    )
  end

  defp update(path, transform, metadata) do
    original = Policy.file(:read!, [path])
    trailing_newline? = String.ends_with?(original, "\n")
    split = String.split(original, "\n", trim: false)
    lines = if trailing_newline?, do: Enum.drop(split, -1), else: split
    updated_lines = transform.(lines)
    suffix = if trailing_newline?, do: "\n", else: ""
    updated = Enum.join(updated_lines, "\n") <> suffix
    :ok = Policy.file(:write!, [path, updated])

    Map.merge(metadata, %{
      path: path,
      before_bytes: byte_size(original),
      after_bytes: byte_size(updated),
      changed?: original != updated
    })
  end

  defp validate_range!(lines, first, last) do
    if last > length(lines) do
      raise ArgumentError, "line range #{first}..#{last} exceeds #{length(lines)} lines"
    end
  end
end
