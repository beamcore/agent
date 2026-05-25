defmodule Beamcore.Agent.Core.ToolDisplayTest do
  use ExUnit.Case

  alias Beamcore.Agent.Core.ToolDisplay

  test "compact labels cover common tools" do
    patch = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@
    -old
    +new
    """

    cases = [
      {"read", %{"filePath" => "README.md"}, "read README.md"},
      {"write", %{"filePath" => "lib/foo.ex", "content" => "abc"}, "write lib/foo.ex (3 bytes)"},
      {"edit", %{"path" => "lib/foo.ex", "new_string" => "updated"}, "edit lib/foo.ex (7 bytes)"},
      {"patch", %{"patch_content" => patch}, "patch 1 files"},
      {"fs", %{"operation" => "mkdir", "path" => "generated"}, "fs mkdir generated"},
      {"git", %{"operation" => "status"}, "git status"},
      {"mix", %{"command" => "test", "args" => "test/agent_test.exs"},
       "mix test test/agent_test.exs"},
      {"task", %{"name" => "Analyze project", "model" => "mistral-medium"},
       "task Analyze project (mistral-medium)"},
      {"image_generation", %{"output_path" => "generated/diagram.png"},
       "image_generation -> generated/diagram.png"}
    ]

    for {name, args, expected} <- cases do
      assert ToolDisplay.label(name, args) == expected
    end
  end

  test "blocked labels reuse compact tool labels" do
    args = %{"filePath" => "scratch/a.ex", "content" => "bad"}

    assert ToolDisplay.label("write", args, :blocked) == "blocked write scratch/a.ex (3 bytes)"
  end

  test "summaries stay compact and avoid raw maps" do
    long_prompt = String.duplicate("inspect the repo ", 30)

    event =
      ToolDisplay.activity(
        "task",
        %{"name" => "dusty_cat", "model" => "mistral-medium", "prompt" => long_prompt},
        :running
      )

    assert event.summary =~ "name: dusty_cat"
    assert event.summary =~ "model: mistral-medium"
    assert String.length(event.summary) < 180
    refute event.label =~ "%{"
    refute event.summary =~ "%{"
    refute inspect(event) =~ long_prompt
  end

  test "byte and file count helpers are pure display data" do
    patch = """
    --- /dev/null
    +++ b/generated/a.png
    --- a/lib/b.ex
    +++ b/lib/b.ex
    """

    assert ToolDisplay.byte_badge(%{"content" => "abc"}) == "(3 bytes)"
    assert ToolDisplay.patch_file_count(patch) == 2
    assert ToolDisplay.patch_file_badge(%{"patch_content" => patch}) == "2 files"
  end

  test "result summaries decode compact structured output" do
    result = Jason.encode!(%{"ok" => true, "files" => ["generated/diagram.png"]})

    assert ToolDisplay.result_summary(result) == "generated/diagram.png"
  end
end
