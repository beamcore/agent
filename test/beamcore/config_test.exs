defmodule Beamcore.ConfigTest do
  use ExUnit.Case, async: false

  alias Beamcore.Config

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_config_test_#{System.unique_integer([:positive])}.dets"
      )

    previous = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    on_exit(fn ->
      restore_config_path(previous)
      File.rm(path)
    end)

    %{path: path}
  end

  test "stores and clears api key in config.dets", %{path: path} do
    refute Config.configured?(:api_key)

    assert :ok = Config.put(:api_key, " test-token ")
    assert Config.configured?(:api_key)
    assert Config.get(:api_key) == "test-token"
    assert File.exists?(path)

    assert :ok = Config.delete(:api_key)
    refute Config.configured?(:api_key)
    assert Config.get(:api_key) == nil
  end

  test "config file uses owner-only permissions where supported", %{path: path} do
    assert :ok = Config.put(:api_key, "test-token")

    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        assert Bitwise.band(mode, 0o777) == 0o600

      {:error, _reason} ->
        flunk("expected config.dets to exist")
    end
  end

  test "rejects blank token" do
    assert {:error, :empty_value} = Config.put(:api_key, "   ")
    refute Config.configured?(:api_key)
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end

# OTP ownership regression coverage. Kept outside the main module to avoid
# changing the original test setup semantics.
defmodule Beamcore.ConfigOwnershipTest do
  use ExUnit.Case, async: false

  test "config store is supervised and serializes concurrent writes" do
    assert is_pid(Process.whereis(Beamcore.Config))

    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_config_owner_#{System.unique_integer([:positive])}.dets"
      )

    previous = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent, :config_dets_path, previous),
        else: Application.delete_env(:agent, :config_dets_path)

      File.rm(path)
    end)

    1..8
    |> Task.async_stream(fn index ->
      Beamcore.Config.put(String.to_atom("otp_test_#{index}"), "value-#{index}")
    end)
    |> Enum.each(fn {:ok, result} -> assert result == :ok end)

    assert Beamcore.Config.get(:otp_test_8) == "value-8"
  end
end
