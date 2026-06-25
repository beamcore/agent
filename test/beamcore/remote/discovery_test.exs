defmodule Beamcore.Remote.DiscoveryTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Beamcore.Remote.Discovery

  setup_all do
    case :net_kernel.start([:"beamcore_host@127.0.0.1", :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :erlang.set_cookie(Node.self(), :beamcore_discovery_cookie)
    :ok
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
      project = start_peer("myproject")
      beamcore = start_peer("beamcore_fake")

      on_exit(fn ->
        stop_peer(project.peer)
        stop_peer(beamcore.peer)
      end)

      %{project: project.node, beamcore: beamcore.node}
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

  defp start_peer(prefix) do
    {:ok, peer, node} =
      :peer.start(%{
        name: :"#{prefix}_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"beamcore_discovery_cookie"],
        env: [{~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}]
      })

    %{peer: peer, node: node}
  end

  defp stop_peer(peer) do
    :peer.stop(peer)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
