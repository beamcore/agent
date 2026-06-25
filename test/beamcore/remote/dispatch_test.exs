defmodule Beamcore.Remote.DispatchTest do
  # End-to-end: Eeva.execute/1 routing through Session/Remote to a real :peer.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :distributed

  alias Beamcore.Agent.Tools.Eeva
  alias Beamcore.Remote.Session
  alias Beamcore.RemoteRunner
  alias Beamcore.Test.Peer

  setup_all do
    Peer.ensure_distributed!()
  end

  setup do
    # Elixir-loaded peer so eval behaves like a real `iex -S mix` project node.
    {peer, node} = Peer.start!("beamcore_dispatch_peer", elixir?: true)

    # A cold peer lazily loads Elixir modules on first eval, so pin a realistic
    # timeout instead of depending on whatever eeva_timeout_ms sits in the
    # ambient config store. Restored afterwards.
    previous_timeout = Beamcore.Config.get(:eeva_timeout_ms)
    Beamcore.Config.put(:eeva_timeout_ms, "10000")

    on_exit(fn ->
      restore_setting(:eeva_timeout_ms, previous_timeout)
      Session.detach()
      Peer.stop(peer)
    end)

    %{peer: peer, node: node}
  end

  defp restore_setting(key, nil), do: Beamcore.Config.delete(key)
  defp restore_setting(key, value), do: Beamcore.Config.put(key, value)

  defp eeva(code), do: Eeva.execute(%{"code" => code}) |> Jason.decode!()

  test "detached: eval runs in the local (agent) VM" do
    assert Session.target() == :local

    result = eeva("node()")

    assert result["ok"]
    assert result["result"] == inspect(Node.self())
  end

  test "attached: eval runs in the project node's VM", %{node: node} do
    assert :ok = Session.attach(node)

    result = eeva("node()")

    assert result["ok"]
    assert result["result"] == inspect(node)
    refute result["result"] == inspect(Node.self())
  end

  test "attached: stdout and return value come back from the remote node", %{node: node} do
    assert :ok = Session.attach(node)

    result = eeva(~s|IO.puts("over here"); 6 * 7|)

    assert result["ok"]
    assert result["stdout"] =~ "over here"
    assert result["result"] == "42"
  end

  test "attached: a raised exception surfaces as a recoverable error", %{node: node} do
    assert :ok = Session.attach(node)

    result = eeva(~s|raise "boom from remote"|)

    refute result["ok"]
    assert result["stderr"] =~ "boom from remote"
    assert result["recoverable"]
    assert result["session_active"]
  end

  test "attached: a missing runner is re-injected and the eval still succeeds", %{node: node} do
    assert :ok = Session.attach(node)
    # Prove it works, then yank the runner out from under it.
    assert eeva("1 + 1")["result"] == "2"

    :erpc.call(node, :code, :purge, [RemoteRunner])
    true = :erpc.call(node, :code, :delete, [RemoteRunner])
    refute :erpc.call(node, :erlang, :function_exported, [RemoteRunner, :version, 0])

    # Remote.run should re-inject transparently and still return a result.
    result = eeva("2 + 2")
    assert result["ok"]
    assert result["result"] == "4"
  end

  test "detach restores local routing", %{node: node} do
    assert :ok = Session.attach(node)
    assert eeva("node()")["result"] == inspect(node)

    assert :ok = Session.detach()
    assert eeva("node()")["result"] == inspect(Node.self())
  end
end
