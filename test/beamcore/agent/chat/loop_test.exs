defmodule Beamcore.Agent.Chat.LoopTest do
  use ExUnit.Case
  alias Beamcore.Agent.Chat.ToolRuntime

  test "complete pasted caps-looking text remains autonomous input" do
    caps = ToolRuntime.default()
    assert ToolRuntime.allowed_tool_names(caps) == ["eeva"]
  end
end
