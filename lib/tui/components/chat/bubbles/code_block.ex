defmodule Beamcore.TUI.Components.Chat.Bubbles.CodeBlock do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.Bubbles.CodeBlock.Eeva
  alias Beamcore.TUI.Components.Chat.SyntaxHighlight
  alias Beamcore.TUI.{Theme, Wrap}
  alias Beamcore.TUI.Wrap.MarkdownParser
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  @collapsed_preview 3

  def eeva_preview_bubble(code, wrap_width, collapsed \\ MapSet.new(), viewport \\ nil) do
    Eeva.render(code, wrap_width, collapsed, viewport)
  end

  def expanded_card(
        prefix,
        text,
        body_width,
        body_style,
        collapsed \\ MapSet.new(),
        viewport_lines \\ nil
      ) do
    segments = MarkdownParser.parse(text)
    indent = "  "

    {lines, _acc} =
      segments
      |> Enum.flat_map_reduce({0, 0}, fn
        {:prose, prose_text}, {block_idx, cum_height} ->
          wrapped =
            prose_text
            |> Wrap.Markdown.normalize_for_display()
            |> Wrap.lines(body_width)

          rendered =
            Enum.map(wrapped, fn line ->
              %Line{spans: [%Span{content: indent <> line, style: body_style}]}
            end)

          {rendered, {block_idx, cum_height + length(rendered)}}

        {:code, lang, code_lines}, {block_idx, cum_height} ->
          is_collapsed = MapSet.member?(collapsed, block_idx)
          max_len = max(body_width - 2, 10)
          code_style = Theme.style(:code_block)
          header_style = Theme.style(:code_header)
          accent = Theme.style(:accent)

          code_start = cum_height + 1

          rendered =
            if is_collapsed do
              collapsed_segment(
                lang,
                code_lines,
                max_len,
                code_style,
                header_style,
                accent,
                indent
              )
            else
              expanded_segment(
                lang,
                code_lines,
                max_len,
                code_style,
                header_style,
                accent,
                indent,
                viewport_lines,
                code_start
              )
            end

          {rendered, {block_idx + 1, cum_height + length(rendered)}}
      end)

    prefix_line = %Line{spans: [%Span{content: prefix <> " ", style: body_style}]}
    all_lines = [prefix_line | lines]

    [
      {%Paragraph{text: all_lines, style: body_style, wrap: false}, length(all_lines)},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:subtle)}, 1}
    ]
  end

  defp collapsed_segment(lang, code_lines, max_len, code_style, header_style, accent, indent) do
    total = length(code_lines)
    preview = Enum.take(code_lines, @collapsed_preview)
    remaining = max(total - @collapsed_preview, 0)

    header = %Line{
      spans: [
        %Span{content: indent, style: header_style},
        %Span{content: "[+]", style: accent},
        %Span{content: " #{lang} \u2502 #{remaining} more lines", style: header_style}
      ]
    }

    highlighted =
      Enum.map(preview, fn line ->
        if elixir_lang?(lang) do
          SyntaxHighlight.highlight_line(line, max_len, code_style)
        else
          %Line{spans: [%Span{content: indent <> truncate(line, max_len), style: code_style}]}
        end
      end)

    [header | highlighted]
  end

  defp expanded_segment(
         lang,
         code_lines,
         max_len,
         code_style,
         header_style,
         accent,
         indent,
         viewport_lines,
         code_start
       ) do
    header = %Line{
      spans: [
        %Span{content: indent, style: header_style},
        %Span{content: "[-]", style: accent},
        %Span{content: " #{lang} \u2502 #{length(code_lines)}L", style: header_style}
      ]
    }

    highlighted =
      case viewport_lines do
        %{first: vp_first, last: vp_last} ->
          code_lines
          |> Enum.with_index()
          |> Enum.map(fn {line, idx} ->
            abs_line = code_start + idx
            is_visible? = abs_line >= vp_first and abs_line <= vp_last
            SyntaxHighlight.viewport_line(line, max_len, code_style, indent, is_visible?)
          end)

        _ ->
          Enum.map(code_lines, fn line ->
            SyntaxHighlight.viewport_line(line, max_len, code_style, indent, true)
          end)
      end

    [header | highlighted]
  end

  defp elixir_lang?(lang), do: lang in ["elixir", "ex", "eex", "heex", "exs"]

  defp truncate(text, max_len) do
    text = to_string(text)

    if String.length(text) <= max_len,
      do: text,
      else: String.slice(text, 0, max(max_len - 1, 0)) <> "\u2026"
  end
end
