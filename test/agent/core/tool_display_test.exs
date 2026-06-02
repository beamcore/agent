defmodule Beamcore.Agent.Core.ToolDisplayTest do
  use ExUnit.Case

  alias Beamcore.Agent.Core.ToolDisplay

  test "compact labels cover common tools" do
    cases = [
      {"read", %{"filePath" => "README.md"}, "read README.md"},
      {"modify_file", %{"path" => "lib/foo.ex", "content" => "abc"},
       "modify_file (write) lib/foo.ex (3 bytes)"},
      {"modify_file",
       %{"path" => "lib/foo.ex", "edits" => [%{"search" => "a", "replace" => "b"}]},
       "modify_file (edit) lib/foo.ex (1 edits)"},
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
    args = %{"path" => "scratch/a.ex", "content" => "bad"}

    assert ToolDisplay.label("modify_file", args, :blocked) ==
             "blocked modify_file (write) scratch/a.ex (3 bytes)"
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
    assert ToolDisplay.byte_badge(%{"content" => "abc"}) == "(3 bytes)"
  end

  test "result summaries decode compact structured output" do
    result = Jason.encode!(%{"ok" => true, "files" => ["generated/diagram.png"]})

    assert ToolDisplay.result_summary(result) == "generated/diagram.png"
  end
end
