defmodule Beamcore.Agent.Tools.PatchTest do
  use ExUnit.Case

  test "applies unified diff" do
    dir = System.tmp_dir!() |> Path.join("agent_patch_test_#{System.unique_integer([:positive])}")
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

    File.rm_rf!(dir)
  end

  test "returns error on invalid patch" do
    dir =
      System.tmp_dir!() |> Path.join("agent_patch_err_test_#{System.unique_integer([:positive])}")

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

    File.rm_rf!(dir)
  end
end
