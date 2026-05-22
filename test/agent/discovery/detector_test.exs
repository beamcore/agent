defmodule Beamcore.Agent.Discovery.DetectorTest do
  use ExUnit.Case
  alias Beamcore.Agent.Discovery.Detector

  setup do
    test_dir = "test_discovery_dir"
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  test "detects elixir project when mix.exs exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "mix.exs"))
    assert Detector.detect(test_dir) == :elixir
  end

  test "detects erlang project when rebar.config exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "rebar.config"))
    assert Detector.detect(test_dir) == :erlang
  end

  test "detects erlang project when erlang.mk exists", %{test_dir: test_dir} do
    File.touch!(Path.join(test_dir, "erlang.mk"))
    assert Detector.detect(test_dir) == :erlang
  end

  test "returns unknown when no indicators exist", %{test_dir: test_dir} do
    assert Detector.detect(test_dir) == :unknown
  end
end
