defmodule Beamcore.TUI.Components.System.Section do
  @moduledoc false

  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}

  # Wraps content_lines in a consistent ┌─ Title ───┐ / └──────┘ box frame.
  #
  # Options:
  #   :icon — override the default ◆ prefix (pass false to omit)
  #   :pad  — left-padding before the box (default "  ")
  def section(title, content_lines, width, opts \\ []) do
    icon = Keyword.get(opts, :icon, "◆")
    pad = Keyword.get(opts, :pad, "  ")

    border = Theme.style(:subtle)
    accent = Theme.style(:accent)

    inner_w = max(width - String.length(pad) - 2, 20)
    title_str = if icon, do: " " <> icon <> " " <> title <> " ", else: " " <> title <> " "
    title_len = String.length(title_str)
    dash_count = max(inner_w - title_len - 1, 2)
    top = "┌" <> title_str <> String.duplicate("─", dash_count) <> "┐"
    bot = "└" <> String.duplicate("─", inner_w) <> "┘"

    padded =
      Enum.map(content_lines, fn %Line{spans: spans} = line ->
        c_len = line_char_len(line)
        need = max(inner_w - 1 - c_len, 0)

        padded_spans =
          if need > 0 and spans != [] do
            last = List.last(spans)
            rest = Enum.drop(spans, -1)
            rest ++ [%{last | content: last.content <> String.duplicate(" ", need)}]
          else
            spans
          end

        %Line{
          spans:
            [%Span{content: pad <> "│ ", style: border}] ++
              padded_spans ++ [%Span{content: " │", style: border}]
        }
      end)

    [
      %Line{spans: [%Span{content: ""}]},
      %Line{spans: [%Span{content: pad <> top, style: accent}]}
    ] ++
      padded ++
      [
        %Line{spans: [%Span{content: pad <> bot, style: accent}]},
        %Line{spans: [%Span{content: ""}]}
      ]
  end

  defp line_char_len(%Line{spans: spans}) do
    spans |> Enum.map(fn s -> String.length(s.content || "") end) |> Enum.sum()
  end
end
