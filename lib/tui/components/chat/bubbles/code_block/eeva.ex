defmodule Beamcore.TUI.Components.Chat.Bubbles.CodeBlock.Eeva do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.SyntaxHighlight
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  def render(code, wrap_width, collapsed \\ MapSet.new()) do
    render(code, wrap_width, collapsed, nil)
  end

  @doc """
  Render eeva code block with optional viewport awareness.

  When `viewport` is `%{first: first, last: last}` (0-indexed visible line range),
  only lines in that range get full syntax highlighting. Others get ultra-fast
  `lean_plain` rendering (~0.5us vs 9-121us via highlight_line).
  """
  def render(code, wrap_width, collapsed, viewport) do
    max_len = max(wrap_width - 4, 10)
    code_style = Theme.style(:code_block)
    accent = Theme.style(:accent)
    indent = "  "

    raw_lines = code |> to_string() |> String.split(~r/\r?\n/)
    total = length(raw_lines)

    if MapSet.member?(collapsed, 0) do
      collapsed_bubble(total, code_style, accent, indent)
    else
      expanded_bubble(raw_lines, total, max_len, code_style, accent, indent, viewport)
    end
  end

  defp collapsed_bubble(total, code_style, accent, indent) do
    header = %Line{
      spans: [
        %Span{content: indent, style: code_style},
        %Span{content: "[+] #{total} lines hidden (Ctrl+E)", style: accent}
      ]
    }

    [
      {%Paragraph{text: [header], style: code_style, wrap: false}, 1},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:subtle)}, 1}
    ]
  end

  defp expanded_bubble(raw_lines, total, max_len, code_style, accent, indent, viewport) do
    header = %Line{
      spans: [
        %Span{content: indent, style: code_style},
        %Span{content: "[-]", style: accent},
        %Span{content: " elixir \u2502 #{total}L", style: code_style}
      ]
    }

    code_lines = render_lines(raw_lines, max_len, code_style, indent, viewport)
    all_lines = [header | code_lines]

    [
      {%Paragraph{text: all_lines, style: code_style, wrap: false}, length(all_lines)},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:subtle)}, 1}
    ]
  end

  # Full highlight for all lines (no viewport info)
  defp render_lines(raw_lines, max_len, code_style, indent, nil) do
    Enum.map(raw_lines, fn line ->
      SyntaxHighlight.viewport_line(line, max_len, code_style, indent, true)
    end)
  end

  # Viewport-aware: only fully highlight visible lines, lean_plain for the rest
  defp render_lines(raw_lines, max_len, code_style, indent, %{first: vis_first, last: vis_last}) do
    vis_first = max(vis_first, 0)
    vis_last = min(vis_last, length(raw_lines) - 1)

    raw_lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      is_visible? = idx >= vis_first and idx <= vis_last
      SyntaxHighlight.viewport_line(line, max_len, code_style, indent, is_visible?)
    end)
  end
end
