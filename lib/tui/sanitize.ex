defmodule Beamcore.TUI.Sanitize do
  @moduledoc """
  Strips ANSI escape sequences and non-printable control characters from
  text before it reaches the TUI rendering pipeline.

  Ratatui manages terminal styling through its own escape sequences. Embedded
  escape codes in content text will render as visible garbage or corrupt the
  display. This module ensures all user/tool/LLM content is safe to display.
  """

  @doc """
  Sanitizes a string for safe TUI display.

  Strips ANSI escape sequences, normalizes line endings, and removes
  non-printable control characters while preserving newlines and converting
  tabs to spaces.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(text) when is_binary(text) do
    if String.valid?(text) do
      text
      |> strip_ansi()
      |> normalize_line_endings()
      |> strip_control_chars()
    else
      text
      |> ensure_valid_utf8()
      |> strip_ansi()
      |> normalize_line_endings()
      |> strip_control_chars()
    end
  end

  def sanitize(nil), do: ""
  def sanitize(other), do: other |> to_string() |> sanitize()

  # CSI sequences: \e[ followed by params and a final byte
  # Covers standard (e.g. \e[32m), private (e.g. \e[?25l), and SGR sequences
  @csi_re ~r/\x1b\[[0-?]*[ -\/]*[@-~]/

  # OSC sequences: \e] ... terminated by BEL (\x07) or ST (\e\\)
  @osc_re ~r/\x1b\].*?(?:\x07|\x1b\\)/s

  # DCS, PM, APC, SOS string sequences: \eP, \e^, \e_, \eX ... terminated by ST
  @string_seq_re ~r/\x1b[P\^_X].*?(?:\x1b\\)/s

  # Single-character escape sequences: \e followed by one byte in 0x20-0x7E range
  # This covers save/restore cursor (\e7, \e8), reset (\ec), etc.
  @single_esc_re ~r/\x1b[ -~]/

  # 8-bit C1 control characters (U+0080-U+009F) including the single-byte CSI (U+009B)
  # These are stripped as bare characters. In the rare case a full 8-bit CSI sequence
  # exists (U+009B + params + final byte), the params/final remain as harmless text.
  @c1_re ~r/[\x{80}-\x{9F}]/u

  defp strip_ansi(text) do
    text
    |> then(&Regex.replace(@csi_re, &1, ""))
    |> then(&Regex.replace(@osc_re, &1, ""))
    |> then(&Regex.replace(@string_seq_re, &1, ""))
    |> then(&Regex.replace(@single_esc_re, &1, ""))
    |> then(&Regex.replace(@c1_re, &1, ""))
  end

  defp normalize_line_endings(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # Remove control chars except newline (\n = 0x0A)
  # Replace tab (\t = 0x09) with spaces for layout stability
  defp strip_control_chars(text) do
    text
    |> String.replace("\t", "  ")
    |> String.replace(~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, "")
  end

  defp ensure_valid_utf8(binary) do
    binary
    |> :unicode.characters_to_binary(:utf8, :utf8)
    |> case do
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end
end
