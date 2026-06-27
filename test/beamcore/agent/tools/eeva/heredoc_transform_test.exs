defmodule Beamcore.Agent.Tools.Eeva.HeredocTransformTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Tools.Eeva.HeredocTransform

  # Helper to build triple-quote strings
  defp dq3, do: String.duplicate("\"", 3)

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # C / C++
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "C / C++ code" do
    test "rewrites C code with printf and \\n escape" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "#include <stdio.h>",
            "printf(\"Hello\\nWorld\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites C code with multiple escape sequences \\n \\t \\\\ " do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"Col1\\tCol2\\nPath: C:\\\\Users\\\\test\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites C++ code with string escapes and regex" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "#include <regex>",
            "std::regex re(\"\\\\d{4}-\\\\d{2}-\\\\d{2}\");",
            "std::cout << \"Match: \" << re_match << std::endl;",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite C code with memset but no escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "char buf[64];",
            "memset(buf, 0, sizeof(buf));",
            "strncpy(buf, src, sizeof(buf) - 1);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # No backslashes triggering current heuristics - requires explicit backslash evidence
      refute output =~ "~S#{dq}"
    end

    test "rewrites C++ with escaped quotes and newlines" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "std::string msg = \"He said \\\"hello\\\"\\n\";",
            "std::cout << msg;",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # \\n at end should trigger
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites C header with backslash path in include" do
      dq = dq3()

      input =
        Enum.join(
          [
            "header = #{dq}",
            "#ifndef MY_HEADER_H",
            "#define MY_HEADER_H",
            "#include \"C:\\\\project\\\\include\\\\utils.h\"",
            "#endif",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "header = ~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Go
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "Go code" do
    test "rewrites Go code with fmt.Printf and \\n" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "package main",
            "import \"fmt\"",
            "func main() {",
            "    fmt.Printf(\"Hello %s\\n\", \"world\")",
            "}",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Go code with regexp and \\d pattern" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "re := regexp.MustCompile(`\\d{4}-\\d{2}-\\d{2}`)",
            "fmt.Println(re.MatchString(\"2024-01-01\"))",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Go code with fmt.Sprintf and tab escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "msg := fmt.Sprintf(\"%s\\t%d\\t%v\", name, count, ok)",
            "fmt.Println(msg)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Go code with raw string literal containing regex" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "pattern := `\\w+\\.\\w+@\\w+\\.\\w+`",
            "re := regexp.MustCompile(pattern)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite Go code with fmt.Println and no escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "package main",
            "import \"fmt\"",
            "func main() {",
            "    fmt.Println(\"Hello, World!\")",
            "}",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # No backslashes, no #{} - safe to leave as bare heredoc
      refute output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Ruby
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "Ruby code" do
    test "rewrites Ruby with puts and string interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "script = #{dq}",
            "name = ARGV[0]",
            "puts \"Hello, \#{name}!\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "script = ~S#{dq}"
    end

    test "rewrites Ruby with require and interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "require 'json'",
            "data = JSON.parse(\"\#{input}\")",
            "puts data",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Ruby with gets and interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "name = gets.chomp",
            "puts \"Welcome, \#{name}!\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Ruby with regex and interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "pattern = /\\d{3}-\\d{4}/",
            "puts \"Phone: \#{phone}\" if phone.match(pattern)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite Ruby with puts but no interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "puts \"Hello, World!\"",
            "puts \"Goodbye!\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # puts is a foreign indicator, but no #{} and no backslashes
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Ruby single-quoted strings without interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "require 'json'",
            "puts 'Hello, World!'",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # JavaScript / TypeScript
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "JavaScript / TypeScript code" do
    test "rewrites JS code with regex containing \\d" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "const re = /\\d{4}-\\d{2}-\\d{2}/;",
            "console.log(re.test('2024-01-01'));",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites JS code with escaped newline in string" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "const msg = \"Hello\\nWorld\";",
            "console.log(msg);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites JS code with escaped backslash in path" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "const path = \"C:\\\\Users\\\\test\\\\file.js\";",
            "console.log(path);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite JS template literal with \${} (safe for Elixir)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "const name = \"world\";",
            "console.log(`Hello ${name}`);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # ${} is NOT Elixir interpolation - safe
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite JS with const and no escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "const x = 42;",
            "const y = x * 2;",
            "console.log(y);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "rewrites TS code with regex and type annotations" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "const pattern: RegExp = /\\w+@\\w+\\.\\w+/;",
            "const validate = (s: string): boolean => pattern.test(s);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites JS with string escape sequences \\n \\t \\\\ " do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "const log = \"Timestamp:\\t\" + Date.now() + \"\\nPath:\\tC:\\\\logs\\\\app.log\";",
            "console.log(log);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Python
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "Python code" do
    test "rewrites Python with \\n in string" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "import sys",
            "print(\"Hello\\nWorld\")",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Python with backslash in Windows path" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "import os",
            "path = \"C:\\\\Users\\\\test\\\\file.py\"",
            "print(os.path.exists(path))",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Python with regex pattern containing escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "import re",
            "pattern = r'\\d{4}-\\d{2}-\\d{2}'",
            "match = re.search(pattern, \"date: 2024-01-15\")",
            "print(match.group())",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Python with raw string containing \\w \\d" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "import re",
            "email_re = r'\\w+@\\w+\\.\\w+'",
            "print(re.findall(email_re, text))",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite Python f-string without backslashes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "name = \"World\"",
            "print(f\"Hello, {name}!\")",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # {name} is NOT Elixir interpolation - safe
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Python with print but no escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "print(\"Hello, World!\")",
            "x = [i**2 for i in range(10)]",
            "print(x)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Python with import but no escapes or interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "import json",
            "data = json.dumps({\"key\": \"value\"})",
            "print(data)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "rewrites Python with template string and tab escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "import json",
            "template = \"Name: \\t{name}\\nAge: \\t{age}\"",
            "result = template.format(name=\"Alice\", age=30)",
            "print(result)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Rust
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "Rust code" do
    test "rewrites Rust with string escape sequences" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "let msg = \"Hello\\nWorld\";",
            "println!(\"{}\", msg);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Rust with regex crate and escape patterns" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "let re = Regex::new(r\"\\d{4}-\\d{2}-\\d{2}\").unwrap();",
            "println!(\"{}\", re.is_match(\"2024-01-01\"));",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Rust with escaped quotes containing \\n" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "let s = \"He said \\\"hello\\\" to me\\n\";",
            "println!(\"{}\", s);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite Rust with format! but no escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "let name = \"World\";",
            "println!(\"Hello, {}!\", name);",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # {} is not Elixir interpolation, no backslashes
      refute output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Java
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "Java code" do
    test "rewrites Java with System.out and escape sequences" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "public static void main(String[] args) {",
            "    System.out.println(\"Hello\\nWorld\");",
            "}",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "rewrites Java with regex and Pattern class" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "Pattern p = Pattern.compile(\"\\\\d{3}-\\\\d{4}\");",
            "Matcher m = p.matcher(\"555-1234\");",
            "System.out.println(m.find());",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not rewrite Java with System.out but no escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "public static void main(String[] args) {",
            "    System.out.println(\"Hello, World!\");",
            "}",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Shell / Bash
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "Shell / Bash code" do
    # TDD: shebang + echo with no escapes currently doesn't trigger rewrite.
    # The shebang is a foreign indicator, but without backslashes or #{}
    # the heuristics require enhancement. This test defines the DESIRED behavior.
    test "TDD: rewrites shell script with shebang even without backslashes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "script = #{dq}",
            "#!/bin/bash",
            "echo \"Hello World\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "script = ~S#{dq}"
    end

    test "rewrites shell script with echo and \\n escape" do
      dq = dq3()

      input =
        Enum.join(
          [
            "script = #{dq}",
            "#!/bin/bash",
            "echo -e \"Hello\\nWorld\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "script = ~S#{dq}"
    end

    # TDD: escaped quotes (backslash + quote) is not in the detection set.
    # This defines DESIRED behavior - \" should be detected as suspicious.
    test "TDD: rewrites shell script with escaped quotes in echo" do
      dq = dq3()

      input =
        Enum.join(
          [
            "script = #{dq}",
            "#!/bin/bash",
            "echo \"He said \\\"hello\\\"\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "script = ~S#{dq}"
    end

    test "does not rewrite shell with echo but no escapes or shebang" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "echo hello",
            "echo world",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "rewrites shell with sed and regex patterns" do
      dq = dq3()

      input =
        Enum.join(
          [
            "script = #{dq}",
            "#!/bin/bash",
            "sed 's/\\d{4}-\\d{2}-\\d{2}/DATE/g' input.txt",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "script = ~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Multiple heredocs in one source
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "multiple heredocs" do
    test "rewrites only the suspicious heredoc among several clean ones" do
      dq = dq3()

      input =
        Enum.join(
          [
            "greeting = #{dq}",
            "IO.puts(\"Hello, World!\")",
            "#{dq}",
            "",
            "ruby_code = #{dq}",
            "puts \"Hello \#{name}\"",
            "#{dq}",
            "",
            "math = #{dq}",
            "result = :math.pow(2, 10)",
            "IO.puts(result)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "greeting = #{dq}"
      assert output =~ "ruby_code = ~S#{dq}"
      assert output =~ "math = #{dq}"
    end

    test "rewrites multiple suspicious heredocs independently" do
      dq = dq3()

      input =
        Enum.join(
          [
            "c_code = #{dq}",
            "printf(\"Hello\\n\");",
            "#{dq}",
            "",
            "go_code = #{dq}",
            "fmt.Printf(\"World\\n\")",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "c_code = ~S#{dq}"
      assert output =~ "go_code = ~S#{dq}"
    end

    test "handles three heredocs: clean, suspicious, clean" do
      dq = dq3()

      input =
        Enum.join(
          [
            "a = #{dq}",
            "IO.puts(\"first\")",
            "#{dq}",
            "",
            "b = #{dq}",
            "puts \"Hello \#{name}\"",
            "#{dq}",
            "",
            "c = #{dq}",
            "IO.puts(\"third\")",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "a = ~S#{dq}"
      assert output =~ "b = ~S#{dq}"
      refute output =~ "c = ~S#{dq}"
    end

    test "handles adjacent heredocs with no blank line between" do
      dq = dq3()

      input =
        Enum.join(
          [
            "a = #{dq}",
            "IO.puts(\"clean\")",
            "#{dq}",
            "b = #{dq}",
            "puts \"Hello \#{name}\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "a = ~S#{dq}"
      assert output =~ "b = ~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Already-protected heredocs (~S and ~s)
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "already-protected heredocs" do
    test "does not rewrite heredoc that is already ~S" do
      dq = dq3()
      input = "code = ~S#{dq}\nputs \"Hello \#{name}\"\n#{dq}"
      output = HeredocTransform.transform(input)
      assert output == input
    end

    test "does not rewrite heredoc that is already ~s (lowercase)" do
      dq = dq3()
      input = "code = ~s#{dq}\nputs \"Hello \#{name}\"\n#{dq}"
      output = HeredocTransform.transform(input)
      assert output == input
    end

    test "does not double-wrap ~S heredoc even with backslashes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = ~S#{dq}",
            "printf(\"Hello\\nWorld\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output == input
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Edge cases: empty, whitespace, no heredocs, single line
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "edge cases" do
    test "returns input unchanged when no heredocs present" do
      input = "x = 1\ny = 2\nIO.puts(x + y)"
      output = HeredocTransform.transform(input)
      assert output == input
    end

    test "returns empty string unchanged" do
      output = HeredocTransform.transform("")
      assert output == ""
    end

    test "handles heredoc with empty content" do
      dq = dq3()
      input = "code = #{dq}\n\n#{dq}"
      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "handles heredoc with only whitespace lines" do
      dq = dq3()
      input = "code = #{dq}\n   \n  \n#{dq}"
      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "handles single line (no heredoc possible)" do
      input = "IO.puts(\"hello\")"
      output = HeredocTransform.transform(input)
      assert output == input
    end

    test "handles heredoc opener with trailing whitespace" do
      dq = dq3()
      input = "code = #{dq}   \nputs \"Hello \#{name}\"\n#{dq}"
      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "handles deeply indented heredoc" do
      dq = dq3()

      input =
        Enum.join(
          [
            "    code = #{dq}",
            "    puts \"Hello \#{name}\"",
            "    #{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Unicode / special characters
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "unicode and special characters" do
    test "does not rewrite heredoc with unicode (no false positive)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "greeting = #{dq}",
            "IO.puts(\"こんにちは世界\")",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite heredoc with emoji (no false positive)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "msg = #{dq}",
            "IO.puts(\"Hello 🌍!\")",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "rewrites heredoc with unicode AND backslash escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"こんにちは\\n世界\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Backslash detection thresholds
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "backslash detection thresholds" do
    test "single line with \\d triggers rewrite (regex escape pattern)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "re = /\\d+/",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "single line with \\w triggers rewrite" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "re = /\\w+/",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "single line with \\s triggers rewrite" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "re = /\\s+/",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "single line with \\n triggers rewrite" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"hello\\n\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "single line with \\t triggers rewrite" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"col1\\tcol2\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "single line with \\r triggers rewrite" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"hello\\r\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "single line with \\b triggers rewrite" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"hello\\b\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "single line with \\\\ (double backslash) triggers rewrite" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "path = \"C:\\\\Users\"",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "code = ~S#{dq}"
    end

    test "does not trigger on \\a (not in detection set)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"alert\\a\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # \a is not in [dswDSWnrtbB] set
      refute output =~ "~S#{dq}"
    end

    test "does not trigger on \\0 (not in detection set)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "char *s = \"hello\\0\";",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not trigger on \\x (not in detection set)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "char *s = \"\\x41\";",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not trigger on \\u (not in detection set)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "printf(\"\\u0041\");",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Elixir code that must NOT be rewritten
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "legitimate Elixir code (no false positives)" do
    test "does not rewrite clean Elixir heredoc" do
      dq = dq3()
      input = "code = #{dq}\nIO.puts(\"Hello world\")\nx = 1 + 2\n#{dq}"
      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Elixir with map interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "map = %{a: 1, b: 2}",
            "IO.inspect(map)",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Elixir with legitimate string interpolation" do
      dq = dq3()

      input =
        Enum.join(
          [
            "name = \"World\"",
            "greeting = #{dq}",
            "Hello \#{name}",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Elixir with Enum.map and pipes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "1..10",
            "|> Enum.map(&(&1 * 2))",
            "|> Enum.sum()",
            "|> IO.puts()",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Elixir with defmodule and do blocks" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "defmodule Foo do",
            "  def bar, do: :ok",
            "end",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      refute output =~ "~S#{dq}"
    end

    test "does not rewrite Elixir with import keyword (false foreign match)" do
      dq = dq3()

      input =
        Enum.join(
          [
            "code = #{dq}",
            "import Enum",
            "map([1,2,3], &(&1 * 2))",
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      # import matches foreign indicator, but no #{} or backslashes
      refute output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Real-world: Elixir writing foreign code (correct heredoc syntax)
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "real-world: Elixir writing foreign code to files" do
    test "rewrites heredoc with Python script written via File.write!" do
      dq = dq3()
      # Correct Elixir heredoc syntax: no ) after opening """
      input =
        Enum.join(
          [
            "File.write!(\"script.py\", #{dq}",
            "import sys",
            "print(\"Hello\\nWorld\")",
            "#{dq})"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "~S#{dq}"
    end

    test "rewrites heredoc with System.cmd and embedded Python with escapes" do
      dq = dq3()

      input =
        Enum.join(
          [
            "System.cmd(\"python3\", [\"-c\", #{dq}",
            "import sys",
            "print(\"Hello\\nWorld\")",
            "#{dq}])"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "~S#{dq}"
    end

    test "rewrites heredoc with Go code written via File.write!" do
      dq = dq3()

      input =
        Enum.join(
          [
            "File.write!(\"main.go\", #{dq}",
            "package main",
            "import \"fmt\"",
            "func main() {",
            "    fmt.Printf(\"Hello\\nWorld\")",
            "}",
            "#{dq})"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "~S#{dq}"
    end

    test "rewrites heredoc with Ruby script via File.write!" do
      dq = dq3()

      input =
        Enum.join(
          [
            "File.write!(\"app.rb\", #{dq}",
            "require 'json'",
            "name = ARGV[0]",
            "puts \"Hello, \#{name}!\"",
            "#{dq})"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "~S#{dq}"
    end

    test "rewrites heredoc with JS script via File.write!" do
      dq = dq3()

      input =
        Enum.join(
          [
            "File.write!(\"app.js\", #{dq}",
            "const re = /\\d{3}-\\d{4}/;",
            "console.log(re.test('555-1234'));",
            "#{dq})"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "~S#{dq}"
    end
  end

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Preservation tests: output structure is maintained
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  describe "structural preservation" do
    test "preserves exact line count after transformation" do
      dq = dq3()

      input_lines = [
        "x = 1",
        "code = #{dq}",
        "puts \"Hello \#{name}\"",
        "#{dq}",
        "y = 2"
      ]

      input = Enum.join(input_lines, "\n")
      output = HeredocTransform.transform(input)
      assert length(String.split(output, "\n")) == length(input_lines)
    end

    test "preserves non-heredoc code lines exactly" do
      dq = dq3()

      input =
        Enum.join(
          [
            "x = 1",
            "y = 2",
            "code = #{dq}",
            "puts \"Hello \#{name}\"",
            "#{dq}",
            "IO.puts(x + y)"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ "x = 1"
      assert output =~ "y = 2"
      assert output =~ "IO.puts(x + y)"
    end

    test "preserves heredoc content exactly (only opener changes)" do
      dq = dq3()
      content_line = "puts \"Hello \#{name}\""

      input =
        Enum.join(
          [
            "code = #{dq}",
            content_line,
            "#{dq}"
          ],
          "\n"
        )

      output = HeredocTransform.transform(input)
      assert output =~ content_line
      assert output =~ "#{dq}"
    end
  end
end
