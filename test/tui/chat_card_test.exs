defmodule Beamcore.TUI.Components.ChatCardTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.Chat
  alias Beamcore.TUI.{State, Theme}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.WidgetList

  defp state(overrides \\ []) do
    State.new(nil, ExRatatui.textarea_new())
    |> Map.merge(Map.new(overrides))
  end

  defp area, do: %Rect{x: 0, y: 0, width: 80, height: 24}

  test "wraps the transcript in a rounded, accent-titled card" do
    %WidgetList{block: block} = Chat.widget(state(), area())

    assert :all in block.borders
    assert block.border_type == :rounded
    assert block.title_style == Theme.style(:accent)
  end

  test "the card title carries the active provider/model" do
    %WidgetList{block: block} =
      Chat.widget(state(provider: "openai", model: "gpt-4o"), area())

    assert block.title == "◆ openai/gpt-4o"
  end

  test "falls back to a plain diamond title without provider metadata" do
    %WidgetList{block: block} = Chat.widget(state(provider: nil, model: nil), area())

    assert block.title == "◆ Chat"
  end

  test "falls back to ASCII framing on non-unicode terminals" do
    %WidgetList{block: block} =
      Chat.widget(state(provider: "openai", model: "gpt-4o", unicode?: false), area())

    assert block.border_type == :plain
    assert block.title == "* openai/gpt-4o"
  end
end
