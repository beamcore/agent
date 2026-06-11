defmodule Beamcore.Agent.Chat.CommandsTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.{Commands, Session}

  setup do
    session = Session.new(nil, screen_type: :agent)
    %{session: session}
  end

  test "/context prints compact context", %{session: session} do
    parent = self()
    assert Commands.execute("context", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "Known session context"
    assert output =~ "Eeva"
  end

  test "/help remains available", %{session: session} do
    parent = self()
    assert Commands.execute("help", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "/help"
  end

  test "new F1 sessions start in autonomous yolo-equivalent mode", %{session: session} do
    assert session.autonomous?
    assert session.runtime_caps.mode == :yolo
    assert session.runtime_caps.autonomous?
  end

  test "legacy safety mode command is not part of the simplified command surface", %{
    session: session
  } do
    parent = self()
    assert Commands.execute("safe", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "Unknown command"
  end

  test "/yolo keeps autonomous execution enabled", %{session: session} do
    parent = self()
    yolo = Commands.execute("yolo", session, output: &send(parent, {:out, &1}))

    assert_receive {:out, output}
    assert output =~ "Autonomous mode enabled"
    assert yolo.autonomous?
    assert yolo.runtime_caps.mode == :yolo
    assert yolo.runtime_caps.autonomous?
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
