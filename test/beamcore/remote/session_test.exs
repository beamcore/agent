defmodule Beamcore.Remote.SessionTest do
  # Exercises injection + attach against a real second BEAM node started with
  # :peer. Not async: it drives the singleton Session and the global node table.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Beamcore.Remote.Injector
  alias Beamcore.Remote.Session
  alias Beamcore.RemoteRunner
  alias Beamcore.Test.Peer

  setup_all do
    Peer.ensure_distributed!()
  end

  setup do
    # Elixir-loaded peer (minus beamcore's ebin) so injection assertions stay
    # honest — the runner is genuinely absent until we inject it.
    {peer, node} = Peer.start!("beamcore_peer", elixir?: true)

    on_exit(fn ->
      Session.detach()
      Peer.stop(peer)
    end)

    %{peer: peer, node: node}
  end

  defp quoted(code), do: Code.string_to_quoted!(code, file: "eeva", line: 1)

  describe "Injector" do
    test "injects the runner onto a node that doesn't have it", %{node: node} do
      refute :erpc.call(node, :erlang, :function_exported, [RemoteRunner, :version, 0])

      assert :ok = Injector.inject(node)

      assert :erpc.call(node, RemoteRunner, :version, []) == RemoteRunner.version()
    end

    test "is idempotent across repeated injects", %{node: node} do
      assert :ok = Injector.inject(node)
      assert :ok = Injector.inject(node)
      assert :erpc.call(node, RemoteRunner, :version, []) == RemoteRunner.version()
    end

    test "the eval runs in the attached node's runtime, not the agent's", %{node: node} do
      assert :ok = Injector.inject(node)

      result = :erpc.call(node, RemoteRunner, :run, [quoted("node()"), %{}])

      assert result.status == :ok
      # The eval observes the PEER as its node — proof it ran over there.
      assert result.result == inspect(node)
      refute result.result == inspect(node())
    end
  end

  describe "Session attach/detach" do
    test "attach connects, injects, and sets the routing target", %{node: node} do
      assert :ok = Session.attach(node)
      assert Session.target() == {:attached, node}
      assert Session.attached?()
      assert %{status: :attached, node: ^node} = Session.status()
    end

    test "detach returns to local routing", %{node: node} do
      assert :ok = Session.attach(node)
      assert :ok = Session.detach()
      assert Session.target() == :local
      refute Session.attached?()
      assert %{status: :detached, node: nil} = Session.status()
    end

    test "attaching to self is rejected" do
      assert {:error, :cannot_attach_to_self} = Session.attach(node())
      assert Session.target() == :local
    end
  end

  describe "auto-detach on node loss" do
    test "a nodedown for the attached node detaches cleanly", %{node: node} do
      assert :ok = Session.attach(node)
      assert Session.attached?()

      # Drive the same path a real :nodedown would, deterministically.
      send(Process.whereis(Session), {:nodedown, node})
      :sys.get_state(Session)

      assert Session.target() == :local
      refute Session.attached?()
    end

    test "a nodedown for some other node is ignored", %{node: node} do
      assert :ok = Session.attach(node)

      send(Process.whereis(Session), {:nodedown, :"someone_else@127.0.0.1"})
      :sys.get_state(Session)

      assert Session.target() == {:attached, node}
    end
  end
end
