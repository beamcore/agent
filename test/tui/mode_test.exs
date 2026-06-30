defmodule Beamcore.TUI.ModeTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Mode

  test "all/0 returns the four modes in F-key order" do
    ids = Enum.map(Mode.all(), & &1.id)
    assert ids == [:chat, :dashboard, :research, :mesh]

    fkeys = Enum.map(Mode.all(), & &1.fkey)
    assert fkeys == ["f1", "f2", "f3", "f4"]
  end

  test "default_id/0 is the chat mode" do
    assert Mode.default_id() == :chat
  end

  test "chat and dashboard are ready; research and mesh are coming soon" do
    refute Mode.coming_soon?(Mode.fetch!(:chat))
    refute Mode.coming_soon?(Mode.fetch!(:dashboard))
    assert Mode.coming_soon?(Mode.fetch!(:research))
    assert Mode.coming_soon?(Mode.fetch!(:mesh))
  end

  test "fetch!/1 returns the mode for a known id and raises for an unknown one" do
    assert %Mode{id: :dashboard, fkey: "f2"} = Mode.fetch!(:dashboard)
    assert_raise KeyError, fn -> Mode.fetch!(:nope) end
  end

  test "by_fkey/1 maps an F-key code to its mode, or nil when unbound" do
    assert %Mode{id: :chat} = Mode.by_fkey("f1")
    assert %Mode{id: :mesh} = Mode.by_fkey("f4")
    assert Mode.by_fkey("f9") == nil
  end

  test "index/1 returns the zero-based position used by the Tabs widget" do
    assert Mode.index(:chat) == 0
    assert Mode.index(:dashboard) == 1
    assert Mode.index(:mesh) == 3
  end

  test "tab_title/1 prefixes the F-key and uses a placeholder name when coming soon" do
    assert Mode.tab_title(Mode.fetch!(:chat)) == "F1 Chat"
    assert Mode.tab_title(Mode.fetch!(:dashboard)) == "F2 Dashboard"
    assert Mode.tab_title(Mode.fetch!(:research)) == "F3 ···"
  end
end
