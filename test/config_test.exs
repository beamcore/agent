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

  test "stores and clears mistral api key in config.dets", %{path: path} do
    refute Config.configured?(:mistral_api_key)

    assert :ok = Config.put_mistral_api_key(" test-token ")
    assert Config.configured?(:mistral_api_key)
    assert Config.mistral_api_key() == "test-token"
    assert File.exists?(path)

    assert :ok = Config.delete_mistral_api_key()
    refute Config.configured?(:mistral_api_key)
    assert Config.mistral_api_key() == nil
  end

  test "config file uses owner-only permissions where supported", %{path: path} do
    assert :ok = Config.put_mistral_api_key("test-token")

    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        assert Bitwise.band(mode, 0o777) == 0o600

      {:error, _reason} ->
        flunk("expected config.dets to exist")
    end
  end

  test "rejects blank token" do
    assert {:error, :empty_value} = Config.put_mistral_api_key("   ")
    refute Config.configured?(:mistral_api_key)
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end
