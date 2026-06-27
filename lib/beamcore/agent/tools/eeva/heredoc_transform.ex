defmodule Beamcore.Agent.Tools.Eeva.HeredocTransform do
  @moduledoc """
  Pre-parse text transformation that rewrites bare `\"""` heredocs to `~S\"""`
  when their content contains patterns that would break under Elixir interpolation
  or escape processing.

  ## Why this exists

  Models frequently embed foreign code (Python, Ruby, Go, JS, etc.) inside Elixir
  heredocs, typically to pass it to `System.cmd` or `File.write!`. Bare `\"""` heredocs
  process `\#{}` interpolation and `\` escape sequences, which corrupts the embedded code.

  `~S\"""` heredocs disable both interpolation and escape processing, preserving the
  literal content.

  ## Heuristics

  Two tiers of detection:

  - **Backslash-heavy** (auto-transform): regex/path escape patterns or 3+
    backslash sequences. Strong signal of foreign code.

  - **Interpolation + corroboration**: Contains `\#{}` AND foreign-language keywords
    (`puts`, `print`, `console.log`, `fmt.`, `import`, `package`, etc.). Catches
    Ruby while avoiding false positives on legitimate Elixir interpolation.
  """

  @doc """
  Transform source code, rewriting suspicious bare `\"""` heredocs.
  Returns the (possibly unchanged) source code.
  """
  def transform(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> do_transform([], %{in_heredoc: false})
    |> Enum.join("\n")
  end

  # --- recursive line walker ---

  defp do_transform([line | rest], acc, %{in_heredoc: false} = state) do
    case detect_heredoc_opener(line) do
      {:bare, _indent} ->
        do_transform(rest, [line | acc], %{
          in_heredoc: true,
          opener_idx: length(acc),
          content_lines: [],
          needs_transform: false
        })

      _ ->
        do_transform(rest, [line | acc], state)
    end
  end

  defp do_transform([line | rest], acc, %{in_heredoc: true} = state) do
    if heredoc_closer?(line) do
      content = Enum.reverse(state.content_lines) |> Enum.join("\n")
      needs? = state.needs_transform or suspicious_content?(content)

      new_acc =
        if needs?, do: rewrite_opener_at(acc, state.opener_idx), else: acc

      do_transform(rest, [line | new_acc], %{in_heredoc: false})
    else
      new_state = %{
        state
        | content_lines: [line | state.content_lines],
          needs_transform: state.needs_transform or suspicious_line?(line)
      }

      do_transform(rest, [line | acc], new_state)
    end
  end

  defp do_transform([], acc, _state), do: Enum.reverse(acc)

  # --- opener detection ---

  defp detect_heredoc_opener(line) do
    trimmed = String.trim_trailing(line)
    dq3 = triple_quote()

    cond do
      String.contains?(trimmed, "~S" <> dq3) or String.contains?(trimmed, "~s" <> dq3) ->
        :no

      String.ends_with?(trimmed, dq3) ->
        {:bare, get_indent(line)}

      true ->
        :no
    end
  end

  defp heredoc_closer?(line), do: String.trim(line) == triple_quote()

  defp triple_quote, do: String.duplicate("\"", 3)

  # --- suspicion heuristics ---

  defp suspicious_line?(line) do
    backslash_suspicious?(line) or interpolation_with_corroboration?(line)
  end

  defp suspicious_content?(content) do
    backslash_heavy?(content) or interpolation_with_corroboration?(content)
  end

  # Tier 1: regex/path backslash patterns on a single line
  defp backslash_suspicious?(line) do
    Regex.match?(~r/\\[dswDSWnrtbB]/, line) or
      String.contains?(line, "\\\\")
  end

  # Tier 1: 3+ backslash sequences across the full content
  defp backslash_heavy?(content) do
    count = content |> String.split("\\") |> length() |> Kernel.-(1)
    count > 2
  end

  # Tier 2: \#{} present AND foreign-language keywords also present
  defp interpolation_with_corroboration?(text) do
    String.contains?(text, "\#{") and has_foreign_indicators?(text)
  end

  defp foreign_indicators do
    [
      # Ruby
      ~r/\bputs\b/,
      ~r/\brequire\b/,
      ~r/\bgets\b/,
      # Python
      ~r/\bprint\s*\(/,
      ~r/\bimport\s+\w+/,
      ~r/\bfrom\s+\w+/,
      # JavaScript / TypeScript
      ~r/\bconsole\.\w+/,
      ~r/\bconst\s+\w+\s*=/,
      ~r/\blet\s+\w+\s*=/,
      # Go
      ~r/\bfmt\.\w+/,
      ~r/\bfunc\s+\w+/,
      ~r/\bpackage\s+\w+/,
      # Java
      ~r/\bSystem\.out/,
      ~r/\bpublic\s+static/,
      # Shell
      ~r/\becho\s+/,
      ~r/^#!\//
    ]
  end

  defp has_foreign_indicators?(text) do
    Enum.any?(foreign_indicators(), &Regex.match?(&1, text))
  end

  # --- rewriting ---

  defp rewrite_opener_at(acc, opener_idx) do
    pos = length(acc) - 1 - opener_idx
    {before, [opener | after_]} = Enum.split(acc, pos)
    dq3 = triple_quote()
    escaped = Regex.escape(dq3)
    {:ok, pattern} = Regex.compile(escaped <> "[[:space:]]*$")
    new_opener = Regex.replace(pattern, opener, "~S" <> dq3)
    before ++ [new_opener | after_]
  end

  defp get_indent(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, indent] -> indent
      _ -> ""
    end
  end
end
