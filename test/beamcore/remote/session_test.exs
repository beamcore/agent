defmodule Beamcore.Remote.SessionTest do
  # Exercises injection + attach against a real second BEAM node started with
  # :peer. Not async: it drives the singleton Session and the global node table.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Beamcore.Remote.Injector
  alias Beamcore.Remote.Session
  alias Beamcore.RemoteRunner

  @cookie :beamcore_remote_test_cookie

  setup_all do
    # :peer needs a distributed host node; mix test runs as :nonode@nohost.
    case :net_kernel.start([:"beamcore_host@127.0.0.1", :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :erlang.set_cookie(Node.self(), @cookie)
    :ok
  end

  setup do
    # Unlinked on purpose (see dispatch_test): a linked peer dies when the test
    # process exits, before on_exit detaches — which would log a spurious
    # nodedown. Unlinked, on_exit detaches cleanly before stopping it.
    {:ok, peer, node} =
      :peer.start(%{
        name: :"beamcore_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"#{@cookie}"],
        # Don't let a peer leave an erl_crash.dump behind on teardown.
        env: [{~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}]
      })

    # A real project node is an Elixir node, so give the peer Elixir — but NOT
    # beamcore's own ebin, so the injection assertions stay honest (the runner
    # is genuinely absent until we inject it).
    elixir_paths = Enum.reject(:code.get_path(), &beamcore_path?/1)
    :erpc.call(node, :code, :add_pathsa, [elixir_paths])
    {:ok, _started} = :erpc.call(node, :application, :ensure_all_started, [:elixir])

    on_exit(fn ->
      Session.detach()
      stop_peer(peer)
    end)

    %{peer: peer, node: node}
  end

  defp stop_peer(peer) do
    :peer.stop(peer)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp beamcore_path?(path), do: to_string(path) =~ "/beamcore/ebin"

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
