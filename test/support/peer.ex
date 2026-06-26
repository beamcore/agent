defmodule Beamcore.Test.Peer do
  @moduledoc """
  Test helper for starting/stopping `:peer` nodes used by the remote-attach
  tests.

  Peers are started **unlinked** so they outlive the test process and can be
  detached cleanly in `on_exit` (a linked peer dies when the test process exits,
  before `on_exit` runs, which would log a spurious nodedown).

  `:peer.start` occasionally fails with `:enoent` when forking a fresh `erl` (a
  transient quirk of some Erlang installs), so `start!/2` retries a few times.
  """

  @cookie ~c"beamcore_test_cookie"
  @crash_dump_off [{~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}]
  @host_node :"beamcore_host@127.0.0.1"

  # Captured at compile time, when cwd is guaranteed to be the project root.
  @project_root File.cwd!()

  @doc "The shared cookie all remote tests use for host + peers."
  def cookie, do: :beamcore_test_cookie

  @doc """
  Ensure the test host is a distributed node with the shared cookie, so `:peer`
  nodes can be started and connected.

  Distribution is normally already up (started in `test_helper.exs`, which also
  excludes the `:distributed`-tagged tests when it can't start). This just
  asserts that and sets the cookie; it starts distribution itself only as a
  fallback for unusual run setups.
  """
  def ensure_distributed! do
    unless Node.alive?(), do: ensure_epmd_started!()

    case start_net_kernel() do
      :ok ->
        :erlang.set_cookie(Node.self(), cookie())
        :ok

      {:error, reason} ->
        raise distribution_start_error(reason)
    end
  end

  @doc false
  def ensure_epmd_started!(
        find_executable \\ &System.find_executable/1,
        cmd \\ &System.cmd/3
      ) do
    case find_executable.("epmd") do
      nil ->
        raise """
        could not start distributed Erlang test node #{@host_node}: epmd executable not found.

        Remote tests start real :peer nodes and require Erlang distribution.
        Install Erlang/OTP with epmd available on PATH, or run these tests in an environment
        that supports distributed Erlang.
        """

      epmd ->
        case cmd.(epmd, ["-daemon"], stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, status} ->
            raise """
            could not start distributed Erlang test node #{@host_node}: epmd -daemon failed with exit #{status}.

            Output:
            #{String.trim(to_string(output))}

            Remote tests start real :peer nodes and require Erlang distribution.
            Check that epmd can bind/listen in this CI or local environment.
            """
        end
    end
  end

  @doc false
  def distribution_start_error(reason) do
    """
    could not start distributed Erlang test node #{@host_node}: #{inspect(reason)}

    Remote tests start real :peer nodes and require Erlang distribution.
    This usually means epmd is unavailable, cannot bind/listen, or TCP distribution
    is blocked in the CI/local environment. Verify that:

      * epmd is installed and available on PATH
      * epmd -daemon can start successfully
      * localhost/127.0.0.1 TCP distribution is allowed
      * no stale epmd/net_kernel state is blocking node registration
    """
  end

  defp start_net_kernel(attempts \\ 3)

  defp start_net_kernel(attempts) when attempts > 0 do
    case :net_kernel.start([@host_node, :longnames]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, _reason} when attempts > 1 ->
        ensure_epmd_started!()
        Process.sleep(100)
        start_net_kernel(attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Start an unlinked peer named `<prefix>_<unique>@127.0.0.1`, retrying on
  transient spawn failures. Returns `{peer, node}`.

  Options:
    * `:cookie` — cookie charlist passed via `-setcookie` (default test cookie)
    * `:elixir?` — load this node's Elixir paths (minus beamcore's own ebin) and
      start `:elixir`, so the peer behaves like a real project node (default
      `false` — a bare node is enough for attach/inject-only tests)
  """
  def start!(prefix, opts \\ []) do
    # Spawning a node inherits the VM cwd; if a prior test left it pointing at a
    # since-deleted temp dir, open_port fails with :enoent. Restore a valid cwd.
    ensure_cwd!()

    {peer, node} =
      with_retry(fn ->
        :peer.start(%{
          name: :"#{prefix}_#{System.unique_integer([:positive])}",
          host: ~c"127.0.0.1",
          longnames: true,
          args: [~c"-setcookie", @cookie],
          env: @crash_dump_off
        })
      end)

    if Keyword.get(opts, :elixir?, false), do: load_elixir(node)

    {peer, node}
  end

  @doc "Stop a peer, ignoring errors if it's already gone."
  def stop(peer) do
    :peer.stop(peer)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_cwd! do
    case File.cwd() do
      {:ok, _} -> :ok
      {:error, _} -> File.cd!(@project_root)
    end
  end

  defp with_retry(fun, attempts \\ 5) do
    case fun.() do
      {:ok, peer, node} ->
        {peer, node}

      {:error, _reason} when attempts > 1 ->
        Process.sleep(50)
        with_retry(fun, attempts - 1)

      {:error, reason} ->
        raise "could not start :peer node after retries: #{inspect(reason)}"
    end
  end

  # Give the peer this node's Elixir code paths (excluding beamcore's own ebin,
  # so injection tests stay honest) and start :elixir — making a bare node behave
  # like a real `iex -S mix` project node.
  defp load_elixir(node) do
    elixir_paths = Enum.reject(:code.get_path(), &(to_string(&1) =~ "/beamcore/ebin"))
    :erpc.call(node, :code, :add_pathsa, [elixir_paths])
    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    :ok
  end
end
