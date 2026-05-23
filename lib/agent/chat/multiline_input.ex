defmodule Beamcore.Agent.Chat.MultilineInput do
  @moduledoc """
  Helpers for collecting pasted multi-line chat input.
  """

  @doc """
  Collect lines until the terminator appears.

  Returns `{:ok, text, rest}` when a complete paste is found, `{:more, text}` when
  the terminator has not appeared yet, and `{:error, :empty, rest}` for empty
  pasted content.
  """
  def collect_until(lines, terminator) when is_list(lines) and is_binary(terminator) do
    case Enum.split_while(lines, &(&1 != terminator)) do
      {collected, [_terminator | rest]} ->
        text =
          collected
          |> Enum.join("\n")
          |> String.trim()

        if text == "" do
          {:error, :empty, rest}
        else
          {:ok, text, rest}
        end

      {collected, []} ->
        {:more, Enum.join(collected, "\n")}
    end
  end
end
