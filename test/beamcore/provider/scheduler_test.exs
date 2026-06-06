defmodule Beamcore.Provider.SchedulerTest do
  use ExUnit.Case, async: true

  alias Beamcore.Provider.Scheduler

  test "provider keys are rate limited independently" do
    name = :"scheduler_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Scheduler.start_link(name: name, default_interval: 80)

    remote = {:mistral, "default", "mistral-medium"}
    local = {:ollama, nil, "functiongemma"}

    assert :ok == Scheduler.wait(remote, name: name)
    assert :ok == Scheduler.wait(local, name: name)

    parent = self()

    Task.start(fn ->
      Scheduler.wait(remote, name: name)
      send(parent, :remote_released)
    end)

    refute_receive :remote_released, 30

    Task.start(fn ->
      Scheduler.wait(local, name: name)
      send(parent, :local_released)
    end)

    refute_receive :local_released, 30
    assert_receive :remote_released, 300
    assert_receive :local_released, 120
  end

  test "cooldown applies only to the affected provider key" do
    name = :"scheduler_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Scheduler.start_link(name: name, default_interval: 0)

    remote = {:mistral, "default", "mistral-medium"}
    local = {:ollama, nil, "functiongemma"}

    assert :ok == Scheduler.cooldown(remote, 80, name: name)

    parent = self()

    Task.start(fn ->
      Scheduler.wait(remote, name: name)
      send(parent, :remote_released)
    end)

    Task.start(fn ->
      Scheduler.wait(local, name: name)
      send(parent, :local_released)
    end)

    assert_receive :local_released, 30
    refute_receive :remote_released, 30
    assert_receive :remote_released, 300
  end
end
