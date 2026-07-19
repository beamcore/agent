defmodule Beamcore.Agent.Tools.Eeva.WriteHelper do
  @moduledoc """
  Safe file-writing helpers for model-authored Eeva code.

  ## Why this exists

  Models frequently struggle with Elixir's string escaping when writing files:
  - `~S` sigil prevents interpolation but the model may forget or misuse it
  - Regular strings corrupt embedded backslashes (`\n`, `\t`, `\\`) and `#{}` interpolation

  This module provides ordinary writes plus exact, anchored edits. Anchored edits
  avoid copying an existing large file into model-authored source code and refuse
  to write when the expected context is missing or ambiguous.

  ## Usage patterns

  Small line-oriented content can be written as a list of lines:

      lines = [
        "#!/bin/bash",
        "echo \"Hello World\"",
        "echo \"Line 2\""
      ]
      WriteHelper.write!("script.sh", lines)

  The helper joins the lines with newlines. For large or quote-heavy model output,
  prefer Eeva's `payloads` channel so the content is not parsed as Elixir source:

      WriteHelper.write!("path.txt", eeva_payloads["content"])

  For binary content (heredocs, pre-built strings), `write!/2` delegates
  directly to `File.write!/2`:

      content = ~S"multi-line content\nwith \"quotes\" and \\n escapes"
      WriteHelper.write!("path.txt", content)
  """

  @doc """
  Write content to a file, creating parent directories if needed.

  Accepts:
  - A binary string (delegates to `File.write!/2`)
  - A list of strings (joins with `\\n` and writes)

  Options are passed through to `File.write/3`.
  """
  @spec write!(Path.t(), binary() | [String.t()], keyword()) :: :ok
  def write!(path, content, opts \\ [])

  def write!(path, content, opts) when is_binary(content) do
    ensure_dir!(path)
    File.write!(path, content, opts)
  end

  def write!(path, content, opts) when is_list(content) do
    ensure_dir!(path)
    binary = Enum.join(content, "\n")
    File.write!(path, binary, opts)
  end

  def write!(path, content, opts) do
    ensure_dir!(path)
    File.write!(path, to_string(content), opts)
  end

  @doc """
  Same as `write!/3` but returns `:ok` or `{:error, reason}`.
  """
  @spec write(Path.t(), binary() | [String.t()], keyword()) :: :ok | {:error, term()}
  def write(path, content, opts \\ [])

  def write(path, content, opts) when is_binary(content) do
    with :ok <- ensure_dir(path) do
      File.write(path, content, opts)
    end
  end

  def write(path, content, opts) when is_list(content) do
    with :ok <- ensure_dir(path) do
      binary = Enum.join(content, "\n")
      File.write(path, binary, opts)
    end
  end

  def write(path, content, opts) do
    with :ok <- ensure_dir(path) do
      File.write(path, to_string(content), opts)
    end
  end

  @doc """
  Apply a sequence of exact replacements and write only after all anchors match.

  Every edit is `{old, replacement}`. Each `old` value must occur exactly once
  in the content produced by the preceding edit. This makes stale or ambiguous
  model context fail without partially modifying the file.

  Large replacement text can be supplied through Eeva's literal payload channel:

      WriteHelper.edit!("lib/example.ex", [
        {"  def old, do: :old", eeva_payloads["replacement"]}
      ])
  """
  @spec edit!(Path.t(), [{binary(), binary() | [String.t()]}]) :: :ok
  def edit!(path, edits) when is_list(edits) do
    original = File.read!(path)
    updated = Enum.reduce(edits, original, &apply_edit!/2)
    File.write!(path, updated)
  end

  @doc "Apply one exact replacement. See `edit!/2`."
  @spec replace!(Path.t(), binary(), binary() | [String.t()]) :: :ok
  def replace!(path, old, replacement), do: edit!(path, [{old, replacement}])

  defp apply_edit!({old, replacement}, content) when is_binary(old) and old != "" do
    matches = :binary.matches(content, old)

    case matches do
      [_one] ->
        :binary.replace(content, old, content_to_binary(replacement))

      [] ->
        raise ArgumentError, "edit anchor was not found; file was not changed"

      many ->
        raise ArgumentError, "edit anchor matched #{length(many)} times; file was not changed"
    end
  end

  defp apply_edit!(_edit, _content) do
    raise ArgumentError, "each edit must be a {non_empty_anchor, replacement} tuple"
  end

  defp content_to_binary(content) when is_binary(content), do: content
  defp content_to_binary(content) when is_list(content), do: Enum.join(content, "\n")

  defp content_to_binary(content) do
    raise ArgumentError,
          "edit replacement must be a string or list of strings, got: #{inspect(content)}"
  end

  defp ensure_dir(path) do
    case Path.dirname(path) do
      "" -> :ok
      "." -> :ok
      dir -> File.mkdir_p(dir)
    end
  end

  defp ensure_dir!(path) do
    case Path.dirname(path) do
      "" -> :ok
      "." -> :ok
      dir -> File.mkdir_p!(dir)
    end
  end
end
