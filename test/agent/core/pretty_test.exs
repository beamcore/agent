defmodule Beamcore.Agent.Core.PrettyTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Core.Pretty

  test "colorize can be disabled" do
    assert Pretty.colorize("text", fn -> "\e[31m" end, false) == "text"
  end

  test "eeva tool calls can be printed" do
    output =
      ExUnit.CaptureIO.capture_io(fn -> Pretty.print_tool_call("eeva", %{"code" => "1 + 1"}) end)

    assert output =~ "eeva"
    assert output =~ "1 + 1"
  end
end
