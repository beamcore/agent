defmodule Beamcore.Test.PeerTest do
  use ExUnit.Case, async: true

  alias Beamcore.Test.Peer

  test "missing epmd fails with an actionable message" do
    error =
      assert_raise RuntimeError, fn ->
        Peer.ensure_epmd_started!(fn "epmd" -> nil end, fn _, _, _ -> {"", 0} end)
      end

    assert error.message =~ "epmd executable not found"
    assert error.message =~ "Remote tests start real :peer nodes"
  end

  test "epmd startup failure is reported clearly" do
    error =
      assert_raise RuntimeError, fn ->
        Peer.ensure_epmd_started!(
          fn "epmd" -> "/bad/epmd" end,
          fn "/bad/epmd", ["-daemon"], [stderr_to_stdout: true] -> {"bind failed", 1} end
        )
      end

    assert error.message =~ "epmd -daemon failed with exit 1"
    assert error.message =~ "bind failed"
    assert error.message =~ "Check that epmd can bind/listen"
  end

  test "distribution startup failure explains nodistribution" do
    message =
      Peer.distribution_start_error(
        {:shutdown, {:failed_to_start_child, :net_kernel, :nodistribution}}
      )

    assert message =~ ":nodistribution"
    assert message =~ "epmd is unavailable"
    assert message =~ "localhost/127.0.0.1 TCP distribution is allowed"
  end
end
