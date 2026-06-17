defmodule Beamcore.TUI.Components.Chat.Bubbles do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.{DiffRenderer, SyntaxHighlight}
  alias Beamcore.TUI.{Theme, Wrap}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  def bubble(label, content, style, wrap_width, kind) do
    body_width = max(wrap_width - 2, 10)

    lines =
      case kind do
        :markdown -> Wrap.markdown_lines(to_string(content), body_width)
        :plain -> Wrap.lines(to_string(content), body_width)
      end

    prefix = label_prefix(label)
    card = card_text(prefix, lines, wrap_width)

    [
      {%Paragraph{text: card, style: style, wrap: false}, line_count(card)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end

  def tool_bubble(label, content, wrap_width),
    do: DiffRenderer.render(label, content, wrap_width)

  def eeva_preview_bubble(code, wrap_width) do
    first_line = %Line{
      spans: [%Span{content: "\u26A1 EEVA", style: Theme.style(:accent)}]
    }

    max_len = max(wrap_width - 4, 10)

    code_lines =
      code
      |> to_string()
      |> String.split(~r/\r?\n/)
      |> Enum.map(&SyntaxHighlight.highlight_line(&1, max_len))

    all_lines = [first_line | code_lines]

    [
      {%Paragraph{text: all_lines, style: Theme.style(:muted), wrap: false}, length(all_lines)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end

  defp label_prefix("You"), do: ">"
  defp label_prefix("Agent"), do: "*"
  defp label_prefix("Tool"), do: "\u00BB"
  defp label_prefix("Modify File"), do: "\u00BB"
  defp label_prefix("Error"), do: "!"
  defp label_prefix("System"), do: "\u00B7"
  defp label_prefix("Helper"), do: "\u00B7"
  defp label_prefix("Memory"), do: "\u25C6"
  defp label_prefix("Checkpoint"), do: "\u25C7"
  defp label_prefix(label), do: label |> to_string() |> String.slice(0, 1)

  defp card_text(prefix, lines, wrap_width) do
    body =
      lines
      |> Enum.flat_map(&split_preserving_width(&1, max(wrap_width - 2, 10)))
      |> Enum.map(&"  #{&1}")

    trimmed_body =
      body
      |> Enum.join("\n")
      |> String.trim()

    ["#{prefix} " <> trimmed_body]
    |> Enum.join("\n")
  end

  defp split_preserving_width(line, width), do: Wrap.lines(to_string(line), width)

  def line_count(text), do: text |> to_string() |> String.split("\n") |> length()
end
