defmodule Beamcore.Helpers.ModifyTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.PathSafety
  alias Beamcore.Agent.Tools.Eeva.Policy
  alias Beamcore.Helpers.Modify

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcore_modify_helper_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = PathSafety.configure_workspace_root(root)
    Policy.install(ToolPolicy.default(), root)

    on_exit(fn ->
      Policy.clear()
      File.rm_rf!(root)

      PathSafety.restore_workspace_root(previous)
    end)

    %{root: root}
  end

  test "reads numbered lines and replaces an exact range", %{root: root} do
    File.write!(Path.join(root, "sample.txt"), "alpha\nbeta\ngamma\n")
    assert Modify.lines("sample.txt", 2, 3) == [{"beta", 2}, {"gamma", 3}]
    assert %{changed?: true} = Modify.replace_range("sample.txt", 2, 2, "BETA")
    assert File.read!(Path.join(root, "sample.txt")) == "alpha\nBETA\ngamma\n"
  end
end
