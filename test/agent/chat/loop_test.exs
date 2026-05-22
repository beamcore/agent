defmodule Beamcore.Agent.Chat.LoopTest do
  use ExUnit.Case
  alias Beamcore.Agent.Chat.Loop

  test "Loop.start/2 function signature is correct" do
    assert is_function(&Loop.start/2, 2)
  end
end
