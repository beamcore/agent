defmodule Beamcore.TUI.Components.Chat.BubblesTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.Chat.Bubbles
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.Paragraph

  defp plain(label, content, role_style) do
    [{%Paragraph{text: lines}, _height}, _spacer] =
      Bubbles.bubble(label, content, role_style, role_style, 40, :plain)

    lines
  end

  test "every line carries a gutter rail styled in the role color" do
    role = Theme.style(:user)
    lines = plain("You", "hello there world", role)

    assert Enum.all?(lines, fn %Line{spans: [rail | _]} ->
             rail.content =~ "▏" and rail.style == role
           end)
  end

  test "the header line shows the glyph and the lowercased role label" do
    [%Line{} = header | _] = plain("You", "hi", Theme.style(:user))
    text = Enum.map_join(header.spans, & &1.content)
    assert text =~ "you"
  end

  test "body content keeps the body style and the message text" do
    role = Theme.style(:error)
    [_header | body] = plain("Error", "boom happened", role)

    body_text = Enum.flat_map(body, & &1.spans) |> Enum.map_join(& &1.content)
    assert body_text =~ "boom happened"
  end

  test "the rendered height matches the number of composed lines" do
    [{%Paragraph{text: lines}, height}, _spacer] =
      Bubbles.bubble("You", "one two three", Theme.style(:user), Theme.style(:user), 40, :plain)

    assert height == length(lines)
  end

  defp markdown(content) do
    [{%Paragraph{text: lines}, _height}, _spacer] =
      Bubbles.bubble("Agent", content, Theme.style(:accent), Theme.style(:base), 40, :markdown)

    lines
  end

  test "the assistant bubble carries the accent gutter rail with an agent header" do
    role = Theme.style(:accent)
    lines = markdown("hello world")

    assert Enum.all?(lines, fn %Line{spans: [rail | _]} ->
             rail.content =~ "▏" and rail.style == role
           end)

    header = Enum.map_join(hd(lines).spans, & &1.content)
    assert header =~ "agent"
  end

  test "code lines inside the assistant bubble are railed too" do
    lines = markdown("intro\n```elixir\nIO.puts(1)\n```")

    assert Enum.all?(lines, fn %Line{spans: [rail | _]} -> rail.content =~ "▏" end)
  end
end
