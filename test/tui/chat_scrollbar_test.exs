defmodule Beamcore.TUI.Components.ChatScrollbarTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.Chat
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Paragraph, Scrollbar, WidgetList}

  defp widget_list(total_height, scroll_offset) do
    %WidgetList{
      items: [{%Paragraph{text: "x"}, total_height}],
      scroll_offset: scroll_offset
    }
  end

  defp area(height), do: %Rect{x: 0, y: 0, width: 80, height: height}

  test "binds content length, position, and viewport when content overflows" do
    # viewport = height - 2 = 18; content 50 → scrollable range 32
    sb = Chat.scrollbar(widget_list(50, 10), area(20))

    assert %Scrollbar{
             orientation: :vertical_right,
             content_length: 32,
             position: 10,
             viewport_content_length: 18
           } = sb
  end

  test "returns nil when the content fits within the viewport" do
    assert Chat.scrollbar(widget_list(5, 0), area(20)) == nil
  end
end
