defmodule Beamcore.Provider.HealthTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.Health

  test "health discovery is supervised and returns configured default models" do
    assert is_pid(Process.whereis(Health))
    assert {:ok, models} = Health.list_models("openai")
    assert "gpt-4o" in models
  end

  test "unknown provider fails without crashing the health process" do
    pid = Process.whereis(Health)
    assert {:error, :unknown_provider} = Health.list_models("missing-provider")
    assert Process.alive?(pid)
  end
end
