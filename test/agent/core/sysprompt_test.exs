defmodule Beamcore.Agent.Core.SysPromptTest do
  use ExUnit.Case

  test "generate/0 includes command execution restriction" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    assert prompt =~ "Command Execution Restriction"
    assert prompt =~ "Direct shell, bash, sh, or any other command execution is **not allowed**"
    assert prompt =~ "You must use only the tools provided above"
  end

  test "generate/0 includes senior self-development objectives" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    assert prompt =~ "general-purpose senior coding agent"
    assert prompt =~ "Improve this codebase safely and incrementally"
    assert prompt =~ "Produce excellent production-quality code"
    assert prompt =~ "smallest meaningful change"
    assert prompt =~ "ExUnit tests"
  end

  test "generate/0 allows standalone coding in other languages" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    assert prompt =~ "write code in any programming language"
    assert prompt =~ "Java"
    assert prompt =~ "Do not refuse standalone coding questions"
    assert prompt =~ "answer directly without tools"
    assert prompt =~ "Use Mix only for this Elixir project's validation"
  end

  test "generate/0 includes code quality principles" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    principles = [
      "SOLID",
      "KISS",
      "DRY",
      "YAGNI",
      "Fail fast",
      "backward-compatible",
      "reviewable"
    ]

    Enum.each(principles, fn principle ->
      assert prompt =~ principle,
             "Expected principle '#{principle}' to be present in the prompt"
    end)
  end

  test "generate/0 includes safety boundaries" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    safety_rules = [
      "workspace boundaries",
      "workspace-relative",
      "Absolute paths",
      "path traversal",
      "symlink escapes",
      "Do not expose, print, commit, or invent secrets",
      ".env",
      ".env.example",
      "Policy block"
    ]

    Enum.each(safety_rules, fn rule ->
      assert prompt =~ rule,
             "Expected safety rule '#{rule}' to be present in the prompt"
    end)
  end

  test "generate/0 includes token and tool discipline" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    expectations = [
      "Do not read whole files",
      "offset/limit",
      "Do not inspect the whole project tree",
      "Do not call task for simple analysis",
      "Keep tool outputs compact"
    ]

    Enum.each(expectations, fn expectation ->
      assert prompt =~ expectation,
             "Expected token discipline rule '#{expectation}' to be present in the prompt"
    end)
  end

  test "generate/0 describes confirmation flow and explicit Policy blocks" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    assert prompt =~ "confirmed pending plan"
    assert prompt =~ "Do not ask normal users to write Policy blocks"
    assert prompt =~ "ask the user to confirm with /confirm"
    assert prompt =~ "mode: restricted_write"
    assert prompt =~ "allowed_write_paths:"
    assert prompt =~ "blocked_tools:"
  end

  test "generate/0 includes all important tools" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    tools = [
      "tree",
      "read",
      "write",
      "edit",
      "patch",
      "grep",
      "glob",
      "fs",
      "git",
      "mix",
      "plan",
      "curl"
    ]

    Enum.each(tools, fn tool ->
      assert prompt =~ tool,
             "Expected tool '#{tool}' to be present in the prompt"
    end)
  end

  test "generate/1 includes Elixir project details" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate(:elixir)

    assert prompt =~ "This is an Elixir project using Mix"
    assert prompt =~ "Source code lives under lib/"
    assert prompt =~ "Tests live under test/ and use ExUnit"
    assert prompt =~ "Dependencies are declared in mix.exs"
    assert prompt =~ "Configuration lives under config/"
  end

  test "generate/1 includes Erlang project details" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate(:erlang)

    assert prompt =~ "This is an Erlang project"
  end

  test "generate/1 includes unknown project details" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate(:unknown)

    assert prompt =~ "Project nature is not fully detected"
  end
end
