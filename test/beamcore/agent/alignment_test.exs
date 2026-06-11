defmodule Beamcore.Agent.AlignmentTest do
  use ExUnit.Case

  alias Beamcore.Alignment

  @test_dir "test/tmp_alignment_test"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    Alignment.clear_claims()

    on_exit(fn ->
      File.rm_rf!(@test_dir)
      Alignment.clear_claims()
    end)

    :ok
  end

  test "successfully claims a file and releases it" do
    path = Path.join(@test_dir, "test_file.txt")
    File.write!(path, "hello")

    assert {:ok, :claimed} = Alignment.claim_file(path, "agent_1", "hash_1")
    assert %{^path => %{agent: "agent_1", hash: "hash_1"}} = Alignment.list_claims()

    # Re-claiming by same agent succeeds
    assert {:ok, :already_claimed} = Alignment.claim_file(path, "agent_1", "hash_1")

    # Release claim
    Alignment.release_file(path, "agent_1")
    assert Alignment.list_claims() == %{}
  end

  test "detects conflict and scores appropriately" do
    path = Path.join(@test_dir, "conflict_file.txt")
    File.write!(path, "hello")

    # Agent 1 claims
    assert {:ok, :claimed} = Alignment.claim_file(path, "agent_1", "hash_abc")

    # Agent 2 claims same file, same hash, instantly (should score 100: 50 base + 30 hash + 20 recency)
    assert {:conflict, 100, "agent_1"} = Alignment.claim_file(path, "agent_2", "hash_abc")

    # Agent 2 claims same file, different hash, instantly (should score 70: 50 base + 0 hash + 20 recency)
    assert {:conflict, 70, "agent_2"} = Alignment.claim_file(path, "agent_3", "hash_xyz")
  end

  # NOTE: The alignment guard was removed from the edit tool. File coordination
  # belongs in a middleware/interceptor layer, not baked into individual tools.
  # The Alignment GenServer itself is tested by the tests above.
end
