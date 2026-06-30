defmodule Beamcore.TUI.Components.Chat.Bubbles do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.Bubbles.CodeBlock
  alias Beamcore.TUI.Components.Chat.DiffRenderer
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  @rail "▏ "

  def bubble(label, content, label_style, body_style, wrap_width, kind, opts \\ []) do
    body_width = max(wrap_width - 2, 10)
    collapsed = Keyword.get(opts, :collapsed_blocks, MapSet.new())
    viewport_lines = Keyword.get(opts, :viewport_lines)
    prefix = label_prefix(label)

    case kind do
      :markdown ->
        markdown_bubble(prefix, content, body_style, body_width, collapsed, viewport_lines)

      :plain ->
        plain_bubble(prefix, label, content, label_style, body_style, body_width)
    end
  end

  def tool_bubble(label, content, wrap_width),
    do: DiffRenderer.render(label, content, wrap_width)

  def eeva_preview_bubble(code, wrap_width, collapsed \\ MapSet.new(), viewport \\ nil),
    do: CodeBlock.eeva_preview_bubble(code, wrap_width, collapsed, viewport)

  defp markdown_bubble(prefix, content, body_style, body_width, collapsed, viewport_lines) do
    CodeBlock.expanded_card(
      prefix,
      to_string(content),
      body_width,
      body_style,
      collapsed,
      viewport_lines
    )
  end

  defp plain_bubble(prefix, label, text, rail_style, body_style, body_width) do
    rail = %Span{content: @rail, style: rail_style}
    header_text = "#{prefix} #{String.downcase(to_string(label))}"
    header = %Line{spans: [rail, %Span{content: header_text, style: rail_style}]}

    body_lines =
      text
      |> Beamcore.TUI.Wrap.lines(body_width)
      |> Enum.map(fn line -> %Line{spans: [rail, %Span{content: line, style: body_style}]} end)

    lines = [header | body_lines]

    [
      {%Paragraph{text: lines, style: body_style, wrap: false}, length(lines)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end

  defp label_prefix("You"), do: "›"
  defp label_prefix("Agent"), do: "*"
  defp label_prefix("Tool"), do: "\u00BB"
  defp label_prefix("Modify File"), do: "\u00BB"
  defp label_prefix("Error"), do: "!"
  defp label_prefix("System"), do: "\u00B7"
  defp label_prefix("Helper"), do: "\u00B7"
  defp label_prefix("Memory"), do: "\u25C6"
  defp label_prefix("Checkpoint"), do: "\u25C7"
  defp label_prefix(label), do: label |> to_string() |> String.slice(0, 1)

  def line_count(%Paragraph{text: lines}) when is_list(lines), do: length(lines)
  def line_count(text), do: text |> to_string() |> String.split("\n") |> length()
end
