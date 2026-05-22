defmodule Beamcore.Agent.Core.SysPromptTest do
  use ExUnit.Case

  test "generate/0 includes command execution restriction in guidelines" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    assert String.contains?(prompt, "Command Execution Restriction")

    assert String.contains?(
             prompt,
             "Direct shell, bash, sh, or any other command execution is **not allowed**"
           )

    assert String.contains?(prompt, "You must use only the tools provided above")
  end

  test "generate/0 includes all default tools" do
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
      "curl"
    ]

    Enum.each(tools, fn tool ->
      assert String.contains?(prompt, tool),
             "Expected tool '#{tool}' to be present in the prompt"
    end)
  end

  test "generate/0 includes all default guidelines" do
    prompt = Beamcore.Agent.Core.SysPrompt.generate()

    guidelines = [
      "Follow project conventions and write clean, readable code",
      "Avoid destructive actions",
      "Explain reasoning for complex decisions or changes",
      "Prioritize optimal and efficient solutions",
      "Work autonomously within a user request scope"
    ]

    Enum.each(guidelines, fn guideline ->
      assert String.contains?(prompt, guideline),
             "Expected guideline '#{guideline}' to be present in the prompt"
    end)
  end

  test "generate/1 includes project nature details" do
    elixir_prompt = Beamcore.Agent.Core.SysPrompt.generate(:elixir)
    assert String.contains?(elixir_prompt, "### Project Nature:")
    assert String.contains?(elixir_prompt, "This is an Elixir project")

    erlang_prompt = Beamcore.Agent.Core.SysPrompt.generate(:erlang)
    assert String.contains?(erlang_prompt, "This is an Erlang project.")

    unknown_prompt = Beamcore.Agent.Core.SysPrompt.generate(:unknown)

    assert String.contains?(
             unknown_prompt,
             "The project nature/language is unknown or not specifically detected."
           )
  end
end
