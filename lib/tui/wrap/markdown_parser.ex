defmodule Beamcore.TUI.Wrap.MarkdownParser do
  @moduledoc false

  @type segment ::
          {:prose, String.t()}
          | {:code, lang :: String.t(), lines :: [String.t()]}

  @doc """
  Split markdown content into alternating prose and code segments.
  """
  @spec parse(String.t()) :: [segment()]
  def parse(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> parse_lines(:prose, nil, [], [])
    |> Enum.reverse()
  end

  defp parse_lines([], :prose, _lang, prose_acc, seg_acc) do
    flush_prose(prose_acc, seg_acc)
  end

  defp parse_lines([], :code, lang, code_acc, seg_acc) do
    flush_code(lang, code_acc, seg_acc)
  end

  defp parse_lines([line | rest], :prose, lang, prose_acc, seg_acc) do
    trimmed = String.trim_leading(line)

    case fence_open(trimmed) do
      {:ok, fence_lang} ->
        new_seg_acc = flush_prose(prose_acc, seg_acc)
        parse_lines(rest, :code, fence_lang, [], new_seg_acc)

      :no ->
        parse_lines(rest, :prose, lang, [line | prose_acc], seg_acc)
    end
  end

  defp parse_lines([line | rest], :code, lang, code_acc, seg_acc) do
    trimmed = String.trim_leading(line)

    if fence_close?(trimmed) do
      new_seg_acc = flush_code(lang, code_acc, seg_acc)
      parse_lines(rest, :prose, nil, [], new_seg_acc)
    else
      parse_lines(rest, :code, lang, [line | code_acc], seg_acc)
    end
  end

  defp fence_open(line) do
    case Regex.run(~r/^```(\w*)/, line) do
      [_, lang] -> {:ok, lang}
      _ -> :no
    end
  end

  defp fence_close?(line), do: String.starts_with?(line, "```")

  defp flush_prose([], seg_acc), do: seg_acc

  defp flush_prose(acc, seg_acc) do
    text = acc |> Enum.reverse() |> Enum.join("\n")
    [{:prose, text} | seg_acc]
  end

  defp flush_code(lang, acc, seg_acc) do
    lines = Enum.reverse(acc)
    [{:code, lang || "", lines} | seg_acc]
  end
end
