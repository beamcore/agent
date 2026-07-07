defmodule Beamcore.TUI.Components.ComingSoonTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.ComingSoon
  alias Beamcore.TUI.Mode
  alias ExRatatui.Widgets.Paragraph

  test "names the mode and marks it coming soon, centered" do
    widget = ComingSoon.widget(Mode.fetch!(:research))

    assert %Paragraph{alignment: :center} = widget
    assert widget.text =~ "Research"
    assert widget.text =~ "Coming soon"
  end

  test "frames the placeholder in the same accent-titled card as the chat" do
    widget = ComingSoon.widget(Mode.fetch!(:research))

    assert :all in widget.block.borders
    assert widget.block.border_type == :rounded
    assert widget.block.title == "◆ Research"
  end

  test "falls back to ASCII framing on non-unicode terminals" do
    widget = ComingSoon.widget(Mode.fetch!(:research), false)

    assert widget.block.border_type == :plain
    assert widget.block.title == "* Research"
  end
end
