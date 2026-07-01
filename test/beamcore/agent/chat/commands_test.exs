defmodule Beamcore.Agent.Chat.CommandsTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.{Commands, Session}

  setup do
    Beamcore.Config.set_active_provider("openai")
    Beamcore.Memory.clear()

    on_exit(fn -> Beamcore.Memory.clear() end)

    session = Session.new(nil, screen_type: :agent)
    %{session: session}
  end

  test "/help remains available", %{session: session} do
    parent = self()
    assert Commands.execute("help", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "/help"
    assert output =~ "/memory list"
  end

  test "/memory lists overview and typed entries", %{session: session} do
    parent = self()
    Beamcore.Memory.remember(:facts, "project", "uses Elixir")
    Beamcore.Memory.remember(:decisions, "storage", "uses DETS")

    assert Commands.execute("memory list", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, overview}
    assert overview =~ "Memory overview:"
    assert overview =~ "facts: 1"
    assert overview =~ "decisions: 1"

    assert Commands.execute("memory list facts", session, output: &send(parent, {:out, &1})) ==
             session

    assert_receive {:out, facts}
    assert facts =~ "Memory facts:"
    assert facts =~ "project: uses Elixir"
    refute facts =~ "storage"
  end

  test "/memory search returns matching entries", %{session: session} do
    parent = self()
    Beamcore.Memory.remember(:patterns, "ui", "keep terminal rendering quiet")
    Beamcore.Memory.remember(:facts, "provider", "oauth2 is generic")

    assert Commands.execute("memory search terminal", session, output: &send(parent, {:out, &1})) ==
             session

    assert_receive {:out, output}
    assert output =~ "Memory search: terminal"
    assert output =~ "patterns/ui: keep terminal rendering quiet"
    refute output =~ "oauth2"
  end

  test "/memory forget deletes a key across types", %{session: session} do
    parent = self()
    Beamcore.Memory.remember(:facts, "shared", "fact")
    Beamcore.Memory.remember(:decisions, "shared", "decision")

    assert Commands.execute("memory forget shared", session, output: &send(parent, {:out, &1})) ==
             session

    assert_receive {:out, output}
    assert output =~ "Forgot memory key shared."
    assert Beamcore.Memory.recall(:facts, "shared") == nil
    assert Beamcore.Memory.recall(:decisions, "shared") == nil
  end

  test "/memory forget deletes a typed key", %{session: session} do
    parent = self()
    Beamcore.Memory.remember(:facts, "shared", "fact")
    Beamcore.Memory.remember(:decisions, "shared", "decision")

    assert Commands.execute("memory forget facts shared", session,
             output: &send(parent, {:out, &1})
           ) ==
             session

    assert_receive {:out, output}
    assert output =~ "Forgot memory facts/shared."
    assert Beamcore.Memory.recall(:facts, "shared") == nil
    assert Beamcore.Memory.recall(:decisions, "shared") == "decision"
  end

  test "/memory clear deletes all entries", %{session: session} do
    parent = self()
    Beamcore.Memory.remember(:facts, "project", "uses Elixir")

    assert Commands.execute("memory clear", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "Cleared all memory entries."
    assert Beamcore.Memory.overview().total == 0
  end

  test "/memory reports usage for invalid commands", %{session: session} do
    parent = self()

    assert Commands.execute("memory search", session, output: &send(parent, {:out, &1})) ==
             session

    assert_receive {:out, output}
    assert output =~ "Usage: /memory search <query>"

    assert Commands.execute("memory wat", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "Invalid /memory command"
  end

  test "legacy safety mode command is not part of the simplified command surface", %{
    session: session
  } do
    parent = self()
    assert Commands.execute("safe", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "Unknown command"
  end

  test "legacy confirmation commands are not part of the command surface", %{session: session} do
    parent = self()
    assert Commands.execute("confirm", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "Unknown command"
  end

  test "runtime capability editing is not part of the simplified command surface", %{
    session: session
  } do
    parent = self()

    assert Commands.execute("capabilities tool git deny", session,
             output: &send(parent, {:out, &1})
           ) ==
             session

    assert_receive {:out, output}
    assert output =~ "Unknown command"
  end
end
