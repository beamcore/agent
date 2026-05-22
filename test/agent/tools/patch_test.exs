defmodule Beamcore.Agent.Tools.PatchTest do
  use ExUnit.Case

  @test_dir "test/tmp_patch_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  test "applies unified diff" do
    dir = Path.join(@test_dir, "apply")
    File.mkdir_p!(dir)
    file_path = Path.join(dir, "target.txt")
    File.write!(file_path, "line 1\nline 2\nline 3\n")

    patch_content = """
    --- a/target.txt
    +++ b/target.txt
    @@ -1,3 +1,3 @@
     line 1
    -line 2
    +line two
     line 3
    """

    params = %{
      "patch_content" => patch_content,
      "workdir" => dir
    }

    output = Beamcore.Agent.Tools.Patch.execute(params)
    assert String.contains?(output, "Patch applied successfully")
    assert File.read!(file_path) == "line 1\nline two\nline 3\n"
  end

  test "returns error on invalid patch" do
    dir = Path.join(@test_dir, "invalid")
    File.mkdir_p!(dir)

    patch_content = """
    --- a/nonexistent.txt
    +++ b/nonexistent.txt
    @@ -1,3 +1,3 @@
     line 1
    -line 2
    +line two
     line 3
    """

    params = %{
      "patch_content" => patch_content,
      "workdir" => dir
    }

    output = Beamcore.Agent.Tools.Patch.execute(params)
    assert String.contains?(output, "Error applying patch")
  end

  test "rejects path traversal in patch headers" do
    patch_content = """
    --- a/../outside.txt
    +++ b/../outside.txt
    @@ -1 +1 @@
    -old
    +new
    """

    output =
      Beamcore.Agent.Tools.Patch.execute(%{
        "patch_content" => patch_content,
        "workdir" => @test_dir
      })

    assert output =~ "path traversal is not allowed"
  end

  test "rejects absolute workdir" do
    output =
      Beamcore.Agent.Tools.Patch.execute(%{
        "patch_content" => "",
        "workdir" => "/tmp"
      })

    assert output =~ "absolute paths are not allowed"
  end
end
