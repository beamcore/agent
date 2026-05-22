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
end
