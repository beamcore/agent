defmodule Beamcore.Text do
  @moduledoc """
  Text sanitization utilities.

  Strips ANSI escape sequences and control characters that can corrupt
  terminal / TUI rendering.  Shared by the eeva worker output pipeline
  and the TUI text wrapper.
  """

  @doc """
  Remove ANSI escapes and stray control characters from `text`.

  Newlines and tabs are preserved.
  """
  @spec sanitize(binary()) :: binary()
  def sanitize(text) when is_binary(text) do
    text
    |> strip_ansi()
    |> strip_controls()
  end

  def sanitize(text), do: sanitize(to_string(text))

  # CSI  sequences: ESC [ ... final-byte
  # OSC  sequences: ESC ] ... BEL
  # Other two-byte ESC sequences
  defp strip_ansi(text) do
    text
    |> then(&Regex.replace(~r/(\x1b\[|\x9b)[0-?]*[ -\/]*[@-~]/u, &1, ""))
    |> then(&Regex.replace(~r/\x1b\][^\x07]*\x07/u, &1, ""))
    |> then(&Regex.replace(~r/\x1b[()\[\]][ABCDHJKMNOPR012su]/u, &1, ""))
  end

  # Remove control characters except newline (0x0A) and tab (0x09)
  defp strip_controls(text) do
    String.replace(text, ~r/[\x00-\x08\x0B-\x0D\x0E-\x1F\x7F]/u, "")
  end
end
