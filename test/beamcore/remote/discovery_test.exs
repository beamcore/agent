defmodule Beamcore.Remote.DiscoveryTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Beamcore.Remote.Discovery
  alias Beamcore.Test.Peer

  setup_all do
    Peer.ensure_distributed!()
  end

  describe "resolve/1" do
    test "leaves a fully-qualified name@host untouched" do
      assert Discovery.resolve("myapp@example.host") == :"myapp@example.host"
    end

    test "appends the agent's host to a bare name" do
      resolved = Discovery.resolve("myapp") |> Atom.to_string()
      assert String.starts_with?(resolved, "myapp@")
    end

    test "trims surrounding whitespace" do
      assert Discovery.resolve("  myapp@h  ") == :myapp@h
    end

    test "blank input resolves to nonode@nohost" do
      assert Discovery.resolve("   ") == :nonode@nohost
    end
  end

  describe "candidates/0" do
    setup do
      {project_peer, project} = Peer.start!("myproject")
      {beamcore_peer, beamcore} = Peer.start!("beamcore_fake")

      on_exit(fn ->
        Peer.stop(project_peer)
        Peer.stop(beamcore_peer)
      end)

      %{project: project, beamcore: beamcore}
    end

    test "lists named project nodes", %{project: project} do
      assert project in Discovery.candidates()
    end

    test "excludes BeamCore's own nodes", %{beamcore: beamcore} do
      refute beamcore in Discovery.candidates()
    end

    test "excludes this node" do
      refute Node.self() in Discovery.candidates()
    end
  end
end
