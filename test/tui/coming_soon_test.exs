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

  test "works for the mesh placeholder too" do
    widget = ComingSoon.widget(Mode.fetch!(:mesh))
    assert widget.text =~ "Mesh"
  end
end
