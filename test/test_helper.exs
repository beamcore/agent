# The :distributed-tagged tests start real :peer nodes, which needs working
# Erlang distribution (EPMD + TCP loopback). Bring it up for local runs; CI
# skips those tests with `mix test --exclude distributed`, since its sandbox
# can't start distribution, so a failure to start here is fine to ignore.
_ =
  try do
    System.cmd("epmd", ["-daemon"])
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

case :net_kernel.start([:"beamcore_host@127.0.0.1", :longnames]) do
  {:ok, _} -> :erlang.set_cookie(Node.self(), :beamcore_test_cookie)
  {:error, {:already_started, _}} -> :erlang.set_cookie(Node.self(), :beamcore_test_cookie)
  {:error, _reason} -> :ok
end

ExUnit.start()
