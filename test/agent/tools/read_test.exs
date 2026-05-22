defmodule Beamcore.Agent.Tools.ReadTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Read

  test "spec/0 returns the expected tool specification" do
    spec = Read.spec()
    assert spec.type == "function"
    assert spec.function.name == "read"
    assert "filePath" in spec.function.parameters.required
  end

  test "execute/1 reads a file successfully" do
    params = %{
      "filePath" => "test/testfile.txt"
    }

    output = Read.execute(params)
    assert output =~ "<path>"
    assert output =~ "testfile.txt"
    assert output =~ "<type>file</type>"
    assert output =~ "<content>"
    assert output =~ "1:"
    assert output =~ "(End of file)"
  end

  test "execute/1 reads a directory successfully" do
    params = %{
      "filePath" => "test/agent/tools"
    }

    output = Read.execute(params)
    assert output =~ "<type>directory</type>"
    assert output =~ "grep_test.exs"
  end

  test "execute/1 respects limit and offset parameters" do
    params = %{
      "filePath" => "test/testfile.txt",
      "offset" => 2,
      "limit" => 2
    }

    output = Read.execute(params)
    assert output =~ "2:"
    refute output =~ "1:"
    assert output =~ "(Showing lines 2-3. 2 lines left. Use offset=4 to continue.)"
  end

  test "execute/1 suggests files if exact match is not found" do
    params = %{
      "filePath" => "test/testfile"
    }

    output = Read.execute(params)
    assert output =~ "Error: File not found"
    assert output =~ "Did you mean one of these?"
    assert output =~ "testfile.txt"
  end

  test "execute/1 rejects absolute paths" do
    output = Read.execute(%{"filePath" => "/etc/passwd"})

    assert output =~ "absolute paths are not allowed"
  end

  test "execute/1 rejects path traversal" do
    output = Read.execute(%{"filePath" => "../secret.txt"})

    assert output =~ "path traversal is not allowed"
  end

  test "execute/1 reports missing files inside workspace as file not found" do
    output = Read.execute(%{"filePath" => "test/missing_file_12345.txt"})

    assert output =~ "Error: File not found"
    refute output =~ "path outside workspace"
  end
end
