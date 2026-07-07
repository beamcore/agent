defmodule Beamcore.TUI.Components.HelpTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.Help
  alias Beamcore.TUI.Theme
  alias ExRatatui.Widgets.Popup

  defp text(%Popup{content: %{text: t}}), do: t

  test "blurb/1 describes what each mode is for" do
    assert Help.blurb(:chat) =~ "agent"
    assert Help.blurb(:dashboard) =~ "usage"
    assert Help.blurb(:research) =~ "Coming soon"
  end

  test "widget/1 headers the mode the reader is currently in" do
    assert Help.widget(:chat) |> text() =~ "Now: F1 Chat"
    assert Help.widget(:dashboard) |> text() =~ "Now: F2 Dashboard"
  end

  test "widget/1 always lists the global navigation and quit/help hints" do
    t = Help.widget(:chat) |> text()
    assert t =~ "F1 Chat"
    assert t =~ "F2 Dashboard"
    assert t =~ "? "
    assert t =~ "Ctrl+C"
  end

  test "widget/1 is a rounded popup with the shared accent-diamond title" do
    assert %Popup{block: block} = Help.widget(:chat)
    assert block.title == "◆ Help"
    assert block.border_type == :rounded
    assert block.title_style == Theme.style(:accent)
  end

  test "widget/2 falls back to ASCII framing on non-unicode terminals" do
    assert %Popup{block: block} = Help.widget(:chat, false)
    assert block.title == "* Help"
    assert block.border_type == :plain
  end

  test "widget/0 defaults to the launch mode" do
    assert Help.widget() == Help.widget(:chat)
  end
end
