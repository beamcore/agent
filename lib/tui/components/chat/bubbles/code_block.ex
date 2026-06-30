defmodule Beamcore.TUI.Components.Chat.Bubbles.CodeBlock do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.Bubbles.CodeBlock.Eeva
  alias Beamcore.TUI.{Theme, Wrap}
  alias Beamcore.TUI.Wrap.MarkdownParser
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  @collapsed_preview 3
  # Syntect theme for fenced code. Dark, reads well against the chat panel and
  # matches the majority of the bundled UI themes.
  @code_theme :base16_ocean_dark

  def eeva_preview_bubble(code, wrap_width, collapsed \\ MapSet.new(), viewport \\ nil) do
    Eeva.render(code, wrap_width, collapsed, viewport)
  end

  def expanded_card(
        prefix,
        label,
        rail_style,
        text,
        body_width,
        body_style,
        collapsed \\ MapSet.new(),
        _viewport_lines \\ nil
      ) do
    segments = MarkdownParser.parse(text)

    {lines, _block_count} =
      segments
      |> Enum.flat_map_reduce(0, fn
        {:prose, prose_text}, block_idx ->
          rendered =
            prose_text
            |> Wrap.Markdown.normalize_for_display()
            |> Wrap.lines(body_width)
            |> Enum.map(fn line -> %Line{spans: [%Span{content: line, style: body_style}]} end)

          {rendered, block_idx}

        {:code, lang, code_lines}, block_idx ->
          rendered =
            if MapSet.member?(collapsed, block_idx) do
              collapsed_segment(lang, code_lines)
            else
              expanded_segment(lang, code_lines)
            end

          {rendered, block_idx + 1}
      end)

    rail = %Span{content: "▏ ", style: rail_style}
    header_text = "#{prefix} #{String.downcase(to_string(label))}"
    header = %Line{spans: [rail, %Span{content: header_text, style: rail_style}]}
    railed = Enum.map(lines, fn %Line{spans: spans} -> %Line{spans: [rail | spans]} end)
    all_lines = [header | railed]

    [
      {%Paragraph{text: all_lines, style: body_style, wrap: false}, length(all_lines)},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:subtle)}, 1}
    ]
  end

  defp collapsed_segment(lang, code_lines) do
    remaining = max(length(code_lines) - @collapsed_preview, 0)
    header = code_header("[+]", "#{lang} \u2502 #{remaining} more lines")
    preview = Enum.take(code_lines, @collapsed_preview)
    [header | highlight_code(preview, lang)]
  end

  defp expanded_segment(lang, code_lines) do
    header = code_header("[-]", "#{lang} \u2502 #{length(code_lines)}L")
    [header | highlight_code(code_lines, lang)]
  end

  defp code_header(marker, label) do
    %Line{
      spans: [
        %Span{content: marker, style: Theme.style(:accent)},
        %Span{content: " #{label}", style: Theme.style(:code_header)}
      ]
    }
  end

  # Native syntect highlighting: 36 languages, themed, returned as styled lines
  # so the gutter rail can still be prepended per line.
  defp highlight_code([], _lang), do: []

  defp highlight_code(code_lines, lang) do
    code_lines
    |> Enum.join("\n")
    |> ExRatatui.CodeBlock.highlight(lang, @code_theme)
  end
end
