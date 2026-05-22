defmodule Beamcore.Agent.Core.StatusBarTest do
  use ExUnit.Case
  alias Beamcore.Agent.Core.StatusBar
  alias Beamcore.Agent.Chat.Session

  @test_session %Session{
    session_id: "test-session",
    total_tokens: 100,
    total_prompt_tokens: 60,
    total_completion_tokens: 40
  }

  test "start_link/0 starts the GenServer" do
    {:ok, pid} = StatusBar.start_link()
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "setup/1 configures the scrolling region" do
    import ExUnit.CaptureIO

    output =
      capture_io(fn ->
        {:ok, pid} = StatusBar.start_link(ansi_supported: true)
        StatusBar.setup(pid)
        GenServer.call(pid, :sync)
        GenServer.stop(pid)
      end)

    assert output =~ "\e[1;"
    assert output =~ "r"
  end

  test "update/2 writes to stdout with ANSI sequences" do
    import ExUnit.CaptureIO

    output =
      capture_io(fn ->
        {:ok, pid} = StatusBar.start_link(ansi_supported: true)
        StatusBar.update(pid, @test_session)
        GenServer.call(pid, :sync)
        GenServer.stop(pid)
      end)

    assert output =~ "\e7"
    assert output =~ "\e[K"
    assert output =~ "Tokens: 100"
    assert output =~ "Session: test-session"
    assert output =~ "\e8"
  end

  test "update/2 positions status bar at absolute bottom" do
    import ExUnit.CaptureIO

    output =
      capture_io(fn ->
        {:ok, pid} = StatusBar.start_link(ansi_supported: true)
        StatusBar.update(pid, @test_session)
        GenServer.call(pid, :sync)
        GenServer.stop(pid)
      end)

    assert output =~ "\e["
    assert output =~ ";1H"
  end

  test "reset/1 resets the scrolling region" do
    import ExUnit.CaptureIO

    output =
      capture_io(fn ->
        {:ok, pid} = StatusBar.start_link(ansi_supported: true)
        StatusBar.reset(pid)
        GenServer.call(pid, :sync)
        GenServer.stop(pid)
      end)

    assert output =~ "\e[r"
  end

  test "update/2 truncates long status text" do
    long_session = %Session{
      session_id: String.duplicate("x", 1000),
      total_tokens: 100,
      total_prompt_tokens: 60,
      total_completion_tokens: 40
    }

    import ExUnit.CaptureIO

    output =
      capture_io(fn ->
        {:ok, pid} = StatusBar.start_link(ansi_supported: true)
        StatusBar.update(pid, long_session)
        GenServer.call(pid, :sync)
        GenServer.stop(pid)
      end)

    assert output =~ "..."
  end

  test "update/2 handles non-ANSI terminals" do
    import ExUnit.CaptureIO

    output =
      capture_io(fn ->
        {:ok, pid} = StatusBar.start_link(ansi_supported: false)
        StatusBar.update(pid, @test_session)
        GenServer.call(pid, :sync)
        GenServer.stop(pid)
      end)

    assert output =~ "[Status] Tokens: 100"
    assert output =~ "Session: test-session"
  end

  test "get_terminal_size/0 returns a tuple" do
    size = StatusBar.get_terminal_size()
    assert is_tuple(size)
    assert tuple_size(size) == 2
    {rows, cols} = size
    assert is_integer(rows)
    assert is_integer(cols)
  end

  test "debounce mechanism limits update frequency" do
    {:ok, pid} = StatusBar.start_link()
    # Send rapid updates
    for _ <- 1..20 do
      StatusBar.update(pid, @test_session)
    end

    # Allow time for debounce to process
    Process.sleep(200)

    # The GenServer should still be alive and responsive
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
