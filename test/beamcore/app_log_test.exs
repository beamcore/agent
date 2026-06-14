defmodule Beamcore.AppLogTest do
  use ExUnit.Case, async: false

  alias Beamcore.AppLog

  setup do
    dir = Path.join(System.tmp_dir!(), "beamcore_app_log_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:agent, :app_log_dir)
    Application.put_env(:agent, :app_log_dir, dir)

    on_exit(fn ->
      restore_log_dir(previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "creates daily log file and writes normal lines", %{dir: dir} do
    AppLog.info("started", subsystem: :test)

    assert File.dir?(dir)
    path = AppLog.log_path(~D[2026-06-14])
    assert path == Path.join(dir, "2026-06-14.txt")

    current = AppLog.log_path()
    assert File.exists?(current)
    assert File.read!(current) =~ "INFO started"
    assert File.read!(current) =~ "subsystem: :test"
  end

  test "writes exceptions with stacktraces" do
    try do
      raise "boom"
    rescue
      error -> AppLog.exception(:error, error, __STACKTRACE__, api_key: "sk-secret-value")
    end

    text = File.read!(AppLog.log_path())
    assert text =~ "RuntimeError"
    assert text =~ "boom"
    assert text =~ "api_key: \"[REDACTED]\""
    refute text =~ "sk-secret-value"
  end

  test "redacts secrets from messages and metadata" do
    AppLog.warn(
      "Authorization: Bearer token-secret password=hunter2 cookie=session-cookie",
      token: "tok-secret-value"
    )

    text = File.read!(AppLog.log_path())
    assert text =~ "Authorization: Bearer [REDACTED]"
    assert text =~ "password=[REDACTED]"
    assert text =~ "cookie=[REDACTED]"
    assert text =~ "token: \"[REDACTED]\""
    refute text =~ "token-secret"
    refute text =~ "tok-secret-value"
    refute text =~ "hunter2"
    refute text =~ "session-cookie"
  end

  test "logging never crashes when path cannot be written" do
    bad_path =
      Path.join(System.tmp_dir!(), "beamcore_app_log_file_#{System.unique_integer([:positive])}")

    File.write!(bad_path, "not a directory")
    previous = Application.get_env(:agent, :app_log_dir)
    Application.put_env(:agent, :app_log_dir, Path.join(bad_path, "logs"))

    try do
      assert :ok == AppLog.error("will be ignored")
    after
      restore_log_dir(previous)
      File.rm(bad_path)
    end
  end

  test "user-facing application error references current log file" do
    assert AppLog.user_message() == "Application error. See #{AppLog.log_path()} for details."
  end

  defp restore_log_dir(nil), do: Application.delete_env(:agent, :app_log_dir)
  defp restore_log_dir(path), do: Application.put_env(:agent, :app_log_dir, path)
end
