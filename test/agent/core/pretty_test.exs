defmodule Beamcore.Agent.Core.PrettyTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

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

  test "modify_file tool call display (write mode) omits full content" do
    content = "defmodule Scratch.A do\n" <> String.duplicate("  def x, do: :ok\n", 20) <> "end\n"

    output =
      capture_io(fn ->
        Pretty.print_tool_call("modify_file", %{"path" => "scratch/a.ex", "content" => content})
      end)

    assert output =~ "scratch/a.ex"
    assert output =~ "bytes"
    refute output =~ "defmodule Scratch.A"
    refute output =~ "def x"
  end

  test "modify_file tool call display (edit mode) shows edit badge" do
    output =
      capture_io(fn ->
        Pretty.print_tool_call("modify_file", %{
          "path" => "scratch/a.ex",
          "edits" => [%{"search" => "old", "replace" => "new"}]
        })
      end)

    assert output =~ "scratch/a.ex"
    assert output =~ "1 edits"
  end

  test "plan tool call display is compact" do
    output =
      capture_io(fn ->
        Pretty.print_tool_call("plan", %{
          "summary" => "Create a small file",
          "create_files" => ["scratch/a.ex"],
          "modify_files" => [],
          "delete_files" => []
        })
      end)

    assert output =~ "plan: 1 files"
    assert output =~ "create: 1"
    refute output =~ "Create a small file"
  end

  test "image generation tool call display is compact" do
    output =
      capture_io(fn ->
        Pretty.print_tool_call("image_generation", %{
          "prompt" => String.duplicate("image prompt ", 40),
          "output_path" => "generated/architecture.png"
        })
      end)

    assert output =~ "generated/architecture.png"
    assert output =~ "prompt:"
    refute output =~ "image prompt image prompt"
  end

  test "fs tool call display matches polished output" do
    old_no_color = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "true")

    output =
      capture_io(fn ->
        Pretty.print_tool_call("fs", %{"operation" => "mkdir", "path" => "lib/new_dir"})
      end)

    if old_no_color,
      do: System.put_env("NO_COLOR", old_no_color),
      else: System.delete_env("NO_COLOR")

    assert output =~ "op: mkdir"
    assert output =~ "path: lib/new_dir"
  end

  test "git tool call display matches polished output" do
    old_no_color = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "true")

    output =
      capture_io(fn ->
        Pretty.print_tool_call("git", %{"operation" => "add", "path" => "lib/agent.ex"})
      end)

    if old_no_color,
      do: System.put_env("NO_COLOR", old_no_color),
      else: System.delete_env("NO_COLOR")

    assert output =~ "op: add"
    assert output =~ "path: lib/agent.ex"
  end

  test "task tool call display matches polished output" do
    old_no_color = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "true")

    output =
      capture_io(fn ->
        Pretty.print_tool_call("task", %{"name" => "sneezing_walrus", "prompt" => "solve it"})
      end)

    if old_no_color,
      do: System.put_env("NO_COLOR", old_no_color),
      else: System.delete_env("NO_COLOR")

    assert output =~ "name: sneezing_walrus"
    assert output =~ "prompt: solve it..."
  end

  test "mix tool call display matches polished output" do
    old_no_color = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "true")

    output =
      capture_io(fn ->
        Pretty.print_tool_call("mix", %{"command" => "test", "args" => "test/agent_test.exs"})
      end)

    if old_no_color,
      do: System.put_env("NO_COLOR", old_no_color),
      else: System.delete_env("NO_COLOR")

    assert output =~ "command: test"
    assert output =~ "args: test/agent_test.exs"
  end
end
