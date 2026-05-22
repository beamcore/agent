defmodule Beamcore.Agent.Core.PrettyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Core.Pretty

  test "colorize/2 applies color to text" do
    colored = Pretty.colorize("test", &Pretty.Colors.bright_red/0)
    assert String.contains?(colored, "\e[91m")
    assert String.contains?(colored, "test")
    assert String.contains?(colored, "\e[0m")
  end

  test "colorize/2 returns plain text when NO_COLOR is set" do
    old_no_color = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "true")

    colored = Pretty.colorize("test", &Pretty.Colors.bright_red/0)
    assert colored == "test"

    if old_no_color,
      do: System.put_env("NO_COLOR", old_no_color),
      else: System.delete_env("NO_COLOR")
  end

  test "supports_color?/0 returns true by default" do
    old_no_color = System.get_env("NO_COLOR")
    System.delete_env("NO_COLOR")

    assert Pretty.supports_color?() == true

    if old_no_color, do: System.put_env("NO_COLOR", old_no_color)
  end

  test "supports_color?/0 returns false when NO_COLOR is set" do
    old_no_color = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "true")

    assert Pretty.supports_color?() == false

    if old_no_color,
      do: System.put_env("NO_COLOR", old_no_color),
      else: System.delete_env("NO_COLOR")
  end
end
