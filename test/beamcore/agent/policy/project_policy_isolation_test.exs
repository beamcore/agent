defmodule Beamcore.Agent.Policy.ProjectPolicyIsolationTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Policy.ProjectPolicy

  test "missing project policy keeps eeva available" do
    policy = ProjectPolicy.default(System.tmp_dir!())
    assert ProjectPolicy.allowed_tool_names(["eeva"], ToolPolicy.default(), policy) == ["eeva"]
  end
end
