defmodule Beamcore.Agent.Tools.WriteTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Write

  @test_dir "test/tmp_write_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  test "write creates a file with content" do
    path = Path.join(@test_dir, "test.txt")
    result = Write.execute(%{"filePath" => path, "content" => "hello world"})

    assert result =~ "Successfully wrote to"
    assert File.read!(path) == "hello world"
  end

  test "write creates parent directories" do
    path = Path.join([@test_dir, "nested", "dir", "test.txt"])
    result = Write.execute(%{"filePath" => path, "content" => "hello nested"})

    assert result =~ "Successfully wrote to"
    assert File.read!(path) == "hello nested"
  end

  test "write rejects absolute paths" do
    result = Write.execute(%{"filePath" => "/tmp/agent_write_outside.txt", "content" => "nope"})

    assert result =~ "absolute paths are not allowed"
  end

  test "write rejects path traversal" do
    result = Write.execute(%{"filePath" => "../agent_write_outside.txt", "content" => "nope"})

    assert result =~ "path traversal is not allowed"
  end

  test "write rejects symlink escapes" do
    workspace_link = Path.join(@test_dir, "outside_link")

    outside_dir =
      Path.join(System.tmp_dir!(), "agent_write_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)

    try do
      case File.ln_s(outside_dir, workspace_link) do
        :ok ->
          result =
            Write.execute(%{
              "filePath" => Path.join(workspace_link, "outside.txt"),
              "content" => "nope"
            })

          assert result =~ "path outside workspace"

        {:error, :enotsup} ->
          :ok
      end
    after
      File.rm_rf!(outside_dir)
    end
  end

  test "write de-obfuscates email protection placeholders like [email protected] into $@" do
    path = Path.join(@test_dir, "deobfuscate.txt")
    result = Write.execute(%{"filePath" => path, "content" => "exec \"[email protected]\" --debug\n"})

    assert result =~ "Successfully wrote to"
    assert File.read!(path) == "exec \"$@\" --debug\n"
  end
end
