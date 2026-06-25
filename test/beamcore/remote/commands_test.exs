defmodule Beamcore.Remote.CommandsTest do
  # Exercises the /attach-/detach TUI command UX and boot_attach against a real
  # :peer. The peer can be bare here: these tests cover attach/detach state and
  # messages, not eval, so the runner only needs to load (no Elixir required).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Beamcore.Remote.Session
  alias Beamcore.TUI.Components.System.Attach
  alias Beamcore.TUI.Events.Commands.Remote, as: RemoteCmd
  alias Beamcore.TUI.State

  @cookie :beamcore_commands_test_cookie

  setup_all do
    case :net_kernel.start([:"beamcore_host@127.0.0.1", :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :erlang.set_cookie(Node.self(), @cookie)
    :ok
  end

  setup do
    {:ok, peer, node} =
      :peer.start(%{
        # Non-beamcore prefix so it shows up as an attachable project candidate.
        name: :"cmdtarget_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"#{@cookie}"],
        env: [{~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}]
      })

    on_exit(fn ->
      Session.detach()
      stop_peer(peer)
    end)

    %{node: node}
  end

  defp stop_peer(peer) do
    :peer.stop(peer)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp state, do: %State{messages: []}
  defp last_message(state), do: state.messages |> List.last() |> Map.get(:content)

  defp render(lines) do
    lines
    |> Enum.flat_map(fn %{spans: spans} -> Enum.map(spans, & &1.content) end)
    |> Enum.join("")
  end

  describe "/attach" do
    test "attaches to a node and reports success", %{node: node} do
      result = RemoteCmd.attach(state(), Atom.to_string(node))

      assert last_message(result) =~ "Attached to #{node}"
      assert Session.target() == {:attached, node}
    end

    test "rejects attaching to the agent's own node with a friendly message" do
      result = RemoteCmd.attach(state(), Atom.to_string(Node.self()))

      assert last_message(result) =~ "this agent's own node"
      assert Session.target() == :local
    end

    test "with no name, lists discovered project nodes", %{node: node} do
      result = RemoteCmd.attach(state(), "")
      message = last_message(result)

      assert message =~ "Project nodes found" or message =~ "No project nodes"
      # Our peer is a candidate (it isn't beamcore-prefixed).
      assert message =~ Atom.to_string(node)
    end
  end

  describe "/detach" do
    test "detaches and returns to local", %{node: node} do
      assert :ok = Session.attach(node)

      result = RemoteCmd.detach(state())

      assert last_message(result) =~ "Detached from #{node}"
      assert Session.target() == :local
    end

    test "when not attached, says so" do
      result = RemoteCmd.detach(state())
      assert last_message(result) =~ "Not attached"
    end
  end

  describe "F3 attach status line" do
    test "renders local when detached" do
      Session.detach()
      text = render(Attach.lines())

      assert text =~ "Eeva runtime"
      assert text =~ "local"
    end

    test "renders the attached node when attached", %{node: node} do
      assert :ok = Session.attach(node)
      text = render(Attach.lines())

      assert text =~ "attached"
      assert text =~ Atom.to_string(node)
    end
  end

  describe "attach_hint_messages/0" do
    test "hints when a project node is discoverable and detached", %{node: node} do
      Session.detach()

      assert [%{role: :system, content: content}] = Beamcore.Remote.attach_hint_messages()
      assert content =~ "/attach"
      assert content =~ Atom.to_string(node)
    end

    test "is silent once attached", %{node: node} do
      assert :ok = Session.attach(node)
      assert Beamcore.Remote.attach_hint_messages() == []
    end
  end

  describe "boot_attach/0" do
    test "is ignored when BEAMCORE_TARGET_NODE is unset" do
      System.delete_env("BEAMCORE_TARGET_NODE")
      assert Beamcore.Remote.boot_attach() == :ignore
    end

    test "attaches to the env-specified node", %{node: node} do
      System.put_env("BEAMCORE_TARGET_NODE", Atom.to_string(node))
      on_exit(fn -> System.delete_env("BEAMCORE_TARGET_NODE") end)

      assert :ok = Beamcore.Remote.boot_attach()
      assert Session.target() == {:attached, node}
    end
  end
end
