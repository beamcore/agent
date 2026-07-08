defmodule Beamcore.Agent.Tools.Eeva.WriteHelper do
  @moduledoc """
  Safe file-writing helpers for model-authored Eeva code.

  ## Why this exists

  Models frequently struggle with Elixir's string escaping when writing files:
  - `~S` sigil prevents interpolation but the model may forget or misuse it
  - Regular strings corrupt embedded backslashes (`\n`, `\t`, `\\`) and `#{}` interpolation

  This module provides `write!/2,3` as a drop-in replacement for `File.write!/2,3`
  that accepts content as a **list of lines** in addition to a binary string.

  ## Usage patterns

  The preferred model pattern is to build content as a list of lines, then write:

      lines = [
        "#!/bin/bash",
        "echo \"Hello World\"",
        "echo \"Line 2\""
      ]
      WriteHelper.write!("script.sh", lines)

  This avoids all escaping issues — each line is a separate string literal,
  and the helper joins them with newlines.

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
