defmodule Beamcore.TUI.Components.Chat.Bubbles do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.Bubbles.CodeBlock
  alias Beamcore.TUI.Components.Chat.DiffRenderer
  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.Paragraph

  def bubble(label, content, _label_style, body_style, wrap_width, kind, opts \\ []) do
    body_width = max(wrap_width - 2, 10)
    collapsed = Keyword.get(opts, :collapsed_blocks, MapSet.new())
    viewport_lines = Keyword.get(opts, :viewport_lines)
    prefix = label_prefix(label)

    case kind do
      :markdown -> markdown_bubble(prefix, content, body_style, body_width, collapsed, viewport_lines)
      :plain -> plain_bubble(prefix, content, body_style, body_width)
    end
  end

  def tool_bubble(label, content, wrap_width),
    do: DiffRenderer.render(label, content, wrap_width)

  def eeva_preview_bubble(code, wrap_width, collapsed \\ MapSet.new(), viewport \\ nil),
    do: CodeBlock.eeva_preview_bubble(code, wrap_width, collapsed, viewport)

  defp markdown_bubble(prefix, content, body_style, body_width, collapsed, viewport_lines) do
    CodeBlock.expanded_card(prefix, to_string(content), body_width, body_style, collapsed, viewport_lines)
  end

  defp plain_bubble(prefix, text, body_style, body_width) do
    wrapped = Beamcore.TUI.Wrap.lines(text, body_width)

    card =
      case wrapped do
        [] -> prefix <> " "
        [first | rest] -> Enum.join(["#{prefix} #{first}" | Enum.map(rest, &"  #{&1}")], "\n")
      end

    [
      {%Paragraph{text: card, style: body_style, wrap: false}, line_count(card)},
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

  def line_count(%Paragraph{text: lines}) when is_list(lines), do: length(lines)
  def line_count(text), do: text |> to_string() |> String.split("\n") |> length()
end
