defmodule Beamcore.Agent.Chat.CommandsTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.{Commands, Session}

  setup do
    Beamcore.Config.set_active_provider("openai")
    session = Session.new(nil, screen_type: :agent)
    %{session: session}
  end

  test "/help remains available", %{session: session} do
    parent = self()
    assert Commands.execute("help", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "/help"
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
