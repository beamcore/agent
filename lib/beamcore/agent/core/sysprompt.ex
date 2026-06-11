defmodule Beamcore.Agent.Core.SysPrompt do
  @moduledoc """
  Delegates system prompt generation to the centralized Beamcore.Agent.Core.Prompts module.
  """

  @doc """
  Generates the primary dev agent system prompt (delegated).
  """
  def generate(language \\ :unknown, build_system \\ :unknown) do
    Beamcore.Agent.Core.Prompts.dev_agent(language, build_system)
  end

  @doc """
  Returns the shared memory guidelines and accumulated memory index (delegated).
  """
  def memory_guidelines_and_index do
    Beamcore.Agent.Core.Prompts.memory_guidelines_and_index()
  end
end
