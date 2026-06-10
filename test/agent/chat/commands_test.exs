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

  test "legacy confirmation commands are not part of the command surface", %{session: session} do
    parent = self()
    assert Commands.execute("confirm", session, output: &send(parent, {:out, &1})) == session
    assert_receive {:out, output}
    assert output =~ "Unknown command"
  end

  test "project policy recognizes only eeva", %{session: session} do
    parent = self()

    assert Commands.execute("policy tool git deny", session, output: &send(parent, {:out, &1})) ==
             session

    assert_receive {:out, output}
    assert output =~ "Unknown tool"
  end
end
