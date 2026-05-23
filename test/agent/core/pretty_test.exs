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

  test "write tool call display omits full content" do
    content = "defmodule Scratch.A do\n" <> String.duplicate("  def x, do: :ok\n", 20) <> "end\n"

    output =
      capture_io(fn ->
        Pretty.print_tool_call("write", %{"filePath" => "scratch/a.ex", "content" => content})
      end)

    assert output =~ "scratch/a.ex"
    assert output =~ "bytes"
    refute output =~ "defmodule Scratch.A"
    refute output =~ "def x"
  end

  test "edit tool call display shows only argument sizes" do
    output =
      capture_io(fn ->
        Pretty.print_tool_call("edit", %{
          "path" => "scratch/a.ex",
          "old_string" => "old text",
          "new_string" => "new text"
        })
      end)

    assert output =~ "scratch/a.ex"
    assert output =~ "old: 8 chars"
    assert output =~ "new: 8 chars"
    refute output =~ "old text"
    refute output =~ "new text"
  end

  test "patch tool call display shows file and line counts" do
    patch = """
    --- /dev/null
    +++ b/scratch/a.ex
    @@ -0,0 +1,2 @@
    +one
    +two
    """

    output =
      capture_io(fn ->
        Pretty.print_tool_call("patch", %{"patch_content" => patch})
      end)

    assert output =~ "scratch/a.ex"
    assert output =~ "1 files"
    assert output =~ "lines"
    refute output =~ "+one"
    refute output =~ "+two"
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
end
