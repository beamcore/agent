defmodule Beamcore.Agent.Tools.Eeva.SandboxUtf8Test do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Tools.Eeva.Sandbox

  describe "UTF-8 validation" do
    test "rejects code with invalid UTF-8 encoding" do
      # Create code with invalid UTF-8 bytes
      invalid_code =
        "IO.puts(\"hello\")\n" <> <<226, 150, 198, 34, 41, 10>> <> "\nIO.puts(\"world\")"

      assert {:error, message} = Sandbox.prepare(invalid_code)
      assert message =~ "invalid UTF-8 encoding"
      assert message =~ "valid Unicode"
    end

    test "accepts code with valid UTF-8 encoding" do
      valid_code = "IO.puts(\"hello world\")"

      assert {:ok, _result} = Sandbox.prepare(valid_code)
    end

    test "accepts code with unicode characters" do
      unicode_code = "IO.puts(\"Hello, 世界! 🌍\")"

      assert {:ok, _result} = Sandbox.prepare(unicode_code)
    end
  end
end
