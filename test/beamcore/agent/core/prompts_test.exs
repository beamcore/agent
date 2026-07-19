defmodule Beamcore.Agent.Core.PromptsTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Core.Prompts

  test "tool-capable prompts share large-file editing guidance" do
    for prompt <- [Prompts.dev_agent(), Prompts.sub_agent("test")] do
      assert prompt =~ "eeva_payloads"
      assert prompt =~ "WriteHelper.edit!"
      assert prompt =~ "Do not copy an existing large file"
      refute prompt =~ "No tool chaining"
    end
  end
end
