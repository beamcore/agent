defmodule Beamcore.Agent.OpenAITest do
  use ExUnit.Case

  alias Beamcore.OpenAI
  alias Beamcore.Agent.TestEnv

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_openai_config_#{System.unique_integer([:positive])}.dets"
      )

    previous = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    on_exit(fn ->
      restore_config_path(previous)
      File.rm(path)
    end)

    %{config_path: path}
  end

  test "client/0 requires MISTRAL_API_KEY" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => nil}, fn ->
      assert_raise OpenAI.MissingConfigError, ~r/Run \/login/, fn -> OpenAI.client() end
    end)
  end

  test "client/0 treats a blank MISTRAL_API_KEY as missing" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "   "}, fn ->
      assert_raise OpenAI.MissingConfigError, ~r/Run \/login/, fn -> OpenAI.client() end
    end)
  end

  test "client/0 uses the default Mistral base URL" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "test-api-key", "MISTRAL_BASE_URL" => nil}, fn ->
      client = OpenAI.client()

      assert client.token == "test-api-key"
      assert client.base_url == "https://api.mistral.ai/v1"
    end)
  end

  test "client/0 uses a custom Mistral base URL" do
    TestEnv.with_env(
      %{
        "MISTRAL_API_KEY" => "test-api-key",
        "MISTRAL_BASE_URL" => "https://mistral.example.test/v1"
      },
      fn ->
        client = OpenAI.client()

        assert client.token == "test-api-key"
        assert client.base_url == "https://mistral.example.test/v1"
      end
    )
  end

  test "client/0 uses config token when OS env is missing" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => nil, "MISTRAL_BASE_URL" => nil}, fn ->
      assert :ok = Beamcore.Config.put_mistral_api_key("stored-token")
      assert OpenAI.client().token == "stored-token"
    end)
  end

  test "OS env token wins over stored config token" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "env-token", "MISTRAL_BASE_URL" => nil}, fn ->
      assert :ok = Beamcore.Config.put_mistral_api_key("stored-token")
      assert OpenAI.client().token == "env-token"
    end)
  end

  test "auth diagnostics report source metadata without token values" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => nil, "MISTRAL_BASE_URL" => nil}, fn ->
      assert :ok = Beamcore.Config.put_mistral_api_key("stored-token")

      diagnostics = OpenAI.auth_diagnostics()

      assert diagnostics.env_token_present? == false
      assert diagnostics.config_token_present? == true
      assert diagnostics.selected_token_source == :config
      assert diagnostics.selected_token_length == String.length("stored-token")
      assert diagnostics.base_url == "https://api.mistral.ai/v1"
      assert diagnostics.model == Beamcore.Agent.Chat.API.default_model()
      assert diagnostics.auth_header_present? == true
      assert diagnostics.auth_header_scheme == "Bearer"
      assert diagnostics.config_dets_mode == "600"
      refute inspect(diagnostics) =~ "stored-token"
    end)
  end

  test "auth diagnostics show env override explicitly" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "env-token", "MISTRAL_BASE_URL" => nil}, fn ->
      assert :ok = Beamcore.Config.put_mistral_api_key("stored-token")

      diagnostics = OpenAI.auth_diagnostics()

      assert diagnostics.env_token_present?
      assert diagnostics.config_token_present?
      assert diagnostics.selected_token_source == :env
      assert diagnostics.selected_token_length == String.length("env-token")
      refute inspect(diagnostics) =~ "env-token"
      refute inspect(diagnostics) =~ "stored-token"
    end)
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end
