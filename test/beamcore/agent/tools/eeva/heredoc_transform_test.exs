defmodule Beamcore.Agent.Tools.Eeva.HeredocTransformTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Tools.Eeva.HeredocTransform

  # Helper to build triple-quote strings
  defp dq3, do: String.duplicate("\"", 3)

  describe "transform/1" do
    test "rewrites heredoc with Ruby string interpolation" do
      dq = dq3()
      input = "code = #{dq}\nputs \"Hello \#{name}\"\n#{dq}"
      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites heredoc with heavy backslash usage" do
      dq = dq3()
      input = "code = #{dq}\npath = \"C:\\\\Users\\\\test\"\nregex = /\\d+\\s+\\w+/\n#{dq}"
      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite heredoc with legitimate Elixir interpolation" do
      dq = dq3()
      input = "name = \"World\"\ngreeting = #{dq}\nHello \#{name}\n#{dq}"
      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite heredoc that is already ~S" do
      dq = dq3()
      input = "code = ~S#{dq}\nputs \"Hello \#{name}\"\n#{dq}"
      output = HeredocTransform.transform(input)
      assert output == input
    end

    test "does not rewrite clean Elixir heredoc" do
      dq = dq3()
      input = "code = #{dq}\nIO.puts(\"Hello world\")\nx = 1 + 2\n#{dq}"
      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "rewrites only suspicious heredocs when multiple present" do
      dq = dq3()
      input = Enum.join([
        "ruby_code = #{dq}",
        "puts \"Hello \#{name}\"",
        "#{dq}",
        "",
        "elixir_code = #{dq}",
        "IO.puts(\"Hello world\")",
        "#{dq}"
      ], "\n")

      output = HeredocTransform.transform(input)
      assert output =~ "ruby_code = ~S#{dq}"
      refute output =~ "elixir_code = ~S#{dq}"
    end

    test "rewrites heredoc with Go regex patterns" do
      dq = dq3()
      input = Enum.join([
        "code = #{dq}",
        "re := regexp.MustCompile(`\\d{4}-\\d{2}-\\d{2}`)",
        "fmt.Println(re.MatchString(\"2024-01-01\"))",
        "#{dq}"
      ], "\n")

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite JS template literals" do
      dq = dq3()
      input = Enum.join([
        "code = #{dq}",
        "const name = \"world\";",
        "console.log(`Hello ${name}`);",
        "#{dq}"
      ], "\n")

      output = HeredocTransform.transform(input)
      # console.log is foreign but no #{} present, and no backslashes
      refute output =~ "~S#{dq}"
    end

    test "rewrites when #{} combined with foreign keyword" do
      dq = dq3()
      input = Enum.join([
        "code = #{dq}",
        "require 'json'",
        "data = JSON.parse(\"\#{input}\")",
        "#{dq}"
      ], "\n")

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "returns input unchanged when no heredocs present" do
      input = "x = 1\ny = 2\nIO.puts(x + y)"
      output = HeredocTransform.transform(input)
      assert output == input
    end
  end
end
