defmodule Beamcore.Provider.SchedulerTest do
  use ExUnit.Case, async: true

  alias Beamcore.Provider.Scheduler

  test "provider keys are rate limited independently" do
    name = :"scheduler_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Scheduler.start_link(name: name, default_interval: 1_000)

    remote = {:openai, "default", "gpt-4o"}
    local = {:custom_local, nil, "small-model"}

    assert :ok == Scheduler.wait(remote, name: name)
    assert :ok == Scheduler.wait(local, name: name)

    parent = self()

    Task.start(fn ->
      Scheduler.wait(remote, name: name)
      send(parent, :remote_released)
    end)

    refute_receive :remote_released, 100

    Task.start(fn ->
      Scheduler.wait(local, name: name, interval: 0)
      send(parent, :local_released)
    end)

    assert_receive :local_released, 500
    refute_receive :remote_released, 100
    assert_receive :remote_released, 1_500
  end

  test "cooldown applies only to the affected provider key" do
    name = :"scheduler_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Scheduler.start_link(name: name, default_interval: 0)

    remote = {:openai, "default", "gpt-4o"}
    local = {:custom_local, nil, "small-model"}

    assert :ok == Scheduler.cooldown(remote, 1_000, name: name)

    parent = self()

    Task.start(fn ->
      Scheduler.wait(remote, name: name)
      send(parent, :remote_released)
    end)

    Task.start(fn ->
      Scheduler.wait(local, name: name)
      send(parent, :local_released)
    end)

    assert_receive :local_released, 500
    refute_receive :remote_released, 100
    assert_receive :remote_released, 1_500
  end

  test "wait callback receives scheduler delay instead of sleeping internally" do
    name = :"scheduler_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Scheduler.start_link(name: name, default_interval: 1_000)
    key = {:openai, "default", "gpt-4o"}
    parent = self()

    assert :ok == Scheduler.wait(key, name: name)

    assert :ok ==
             Scheduler.wait(key,
               name: name,
               wait_fun: fn delay ->
                 send(parent, {:scheduler_wait, delay})
               end
             )

    assert_receive {:scheduler_wait, delay}
    assert delay > 0
  end
end
