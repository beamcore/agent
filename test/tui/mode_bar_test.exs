defmodule Beamcore.TUI.Components.ModeBarTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.ModeBar
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Tabs

  test "renders every mode as a tab title in F-key order" do
    tabs = ModeBar.tabs(:chat)

    assert %Tabs{} = tabs
    titles = Enum.map(tabs.titles, & &1.content)
    assert titles == ["F1 Chat", "F2 Dashboard", "F3 ···"]
  end

  test "selects the active mode by index" do
    assert ModeBar.tabs(:chat).selected == 0
    assert ModeBar.tabs(:dashboard).selected == 1
    assert ModeBar.tabs(:research).selected == 2
  end

  test "highlights the active tab with a filled accent chip" do
    assert ModeBar.tabs(:chat).highlight_style == Theme.chip_style()
  end

  test "the selected coming-soon tab reveals its real name" do
    titles = Enum.map(ModeBar.tabs(:research).titles, & &1.content)
    assert titles == ["F1 Chat", "F2 Dashboard", "F3 Research"]
  end

  test "falls back to an ASCII placeholder on non-unicode terminals" do
    titles = Enum.map(ModeBar.tabs(:chat, false).titles, & &1.content)
    assert titles == ["F1 Chat", "F2 Dashboard", "F3 ..."]
  end

  test "styles live modes with status and coming-soon modes with muted" do
    [chat, _dashboard, research] = ModeBar.tabs(:chat).titles

    assert %Span{content: "F1 Chat", style: chat_style} = chat
    assert chat_style == Theme.style(:status)

    assert %Span{content: "F3 ···", style: research_style} = research
    assert research_style == Theme.style(:muted)
  end
end
