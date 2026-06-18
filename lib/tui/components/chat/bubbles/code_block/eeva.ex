defmodule Beamcore.TUI.Components.Chat.Bubbles.CodeBlock.Eeva do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.SyntaxHighlight
  alias Beamcore.TUI.{Theme, Wrap}
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  @collapsed_preview 3

  def render(code, wrap_width, collapsed \\ MapSet.new()) do
    max_len = max(wrap_width - 4, 10)
    code_style = Theme.style(:code_block)
    accent = Theme.style(:accent)
    indent = "  "

    raw_lines = code |> to_string() |> String.split(~r/\r?\n/)
    total = length(raw_lines)

    if MapSet.member?(collapsed, 0) do
      collapsed_bubble(raw_lines, total, max_len, code_style, accent, indent)
    else
      expanded_bubble(raw_lines, total, max_len, code_style, accent, indent)
    end
  end

  defp collapsed_bubble(raw_lines, total, max_len, code_style, accent, indent) do
    preview = Enum.take(raw_lines, @collapsed_preview)
    wrapped = Enum.flat_map(preview, &Wrap.lines(&1, max_len))
    remaining = max(total - @collapsed_preview, 0)

    header = %Line{
      spans: [
        %Span{content: indent, style: code_style},
        %Span{content: "[+] #{remaining} more lines (Ctrl+E)", style: accent}
      ]
    }

    code_lines =
      Enum.map(wrapped, fn line ->
        SyntaxHighlight.highlight_line(line, max_len, code_style)
      end)

    all_lines = [header | code_lines]

    [
      {%Paragraph{text: all_lines, style: code_style, wrap: false}, length(all_lines)},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:subtle)}, 1}
    ]
  end

  defp expanded_bubble(raw_lines, total, max_len, code_style, accent, indent) do
    header = %Line{
      spans: [
        %Span{content: indent, style: code_style},
        %Span{content: "[-]", style: accent},
        %Span{content: " elixir \u2502 #{total}L", style: code_style}
      ]
    }

    code_lines =
      Enum.map(raw_lines, fn line ->
        SyntaxHighlight.highlight_line(line, max_len, code_style)
      end)

    all_lines = [header | code_lines]

    [
      {%Paragraph{text: all_lines, style: code_style, wrap: false}, length(all_lines)},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:subtle)}, 1}
    ]
  end
end
