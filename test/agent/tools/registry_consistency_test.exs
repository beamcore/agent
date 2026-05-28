defmodule Beamcore.Agent.Tools.RegistryConsistencyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Core.ToolDisplay
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.Dispatcher

  test "registered tools are present in ToolPolicy, ProjectPolicy, display, and README" do
    names = Dispatcher.registered_tool_names()

    tool_policy_names =
      ToolPolicy.allowed_tool_names(ToolPolicy.yolo(project_policy_bypassed?: true))

    project_policy_names = ProjectPolicy.known_tools()
    readme = File.read!("README.md")

    for name <- names do
      assert name in tool_policy_names
      assert name in project_policy_names

      assert is_binary(ToolDisplay.label(name, %{"command" => "test", "path" => "README.md"}))
      assert readme =~ "`#{name}`"
    end
  end
end
