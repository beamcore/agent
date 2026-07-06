defmodule Beamcore.TUI.ModeTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Mode

  test "all/0 returns the three modes in F-key order" do
    ids = Enum.map(Mode.all(), & &1.id)
    assert ids == [:chat, :dashboard, :research]

    fkeys = Enum.map(Mode.all(), & &1.fkey)
    assert fkeys == ["f1", "f2", "f3"]
  end

  test "default_id/0 is the chat mode" do
    assert Mode.default_id() == :chat
  end

  test "chat and dashboard are ready; research is coming soon" do
    refute Mode.coming_soon?(Mode.fetch!(:chat))
    refute Mode.coming_soon?(Mode.fetch!(:dashboard))
    assert Mode.coming_soon?(Mode.fetch!(:research))
  end

  test "fetch!/1 returns the mode for a known id and raises for an unknown one" do
    assert %Mode{id: :dashboard, fkey: "f2"} = Mode.fetch!(:dashboard)
    assert_raise KeyError, fn -> Mode.fetch!(:nope) end
  end

  test "by_fkey/1 maps an F-key code to its mode, or nil when unbound" do
    assert %Mode{id: :chat} = Mode.by_fkey("f1")
    assert %Mode{id: :research} = Mode.by_fkey("f3")
    assert Mode.by_fkey("f4") == nil
    assert Mode.by_fkey("f9") == nil
  end

  test "index/1 returns the zero-based position used by the Tabs widget" do
    assert Mode.index(:chat) == 0
    assert Mode.index(:dashboard) == 1
    assert Mode.index(:research) == 2
  end

  test "tab_title/1 prefixes the F-key and uses a placeholder name when coming soon" do
    assert Mode.tab_title(Mode.fetch!(:chat)) == "F1 Chat"
    assert Mode.tab_title(Mode.fetch!(:dashboard)) == "F2 Dashboard"
    assert Mode.tab_title(Mode.fetch!(:research)) == "F3 ···"
  end

  test "tab_title/2 reveals a coming-soon mode's real name when it is active" do
    assert Mode.tab_title(Mode.fetch!(:research), true) == "F3 Research"
    # An inactive placeholder still hides behind the ellipsis.
    assert Mode.tab_title(Mode.fetch!(:research), false) == "F3 ···"
    # Ready modes read the same either way.
    assert Mode.tab_title(Mode.fetch!(:chat), true) == "F1 Chat"
  end
end
