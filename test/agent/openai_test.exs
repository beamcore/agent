defmodule Beamcore.Agent.OpenAITest do
  use ExUnit.Case

  alias Beamcore.Agent.OpenAI
  alias Beamcore.Agent.TestEnv

  test "client/0 requires MISTRAL_API_KEY" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => nil}, fn ->
      assert_raise RuntimeError,
                   "MISTRAL_API_KEY environment variable is required for Mistral API calls.",
                   fn -> OpenAI.client() end
    end)
  end

  test "client/0 treats a blank MISTRAL_API_KEY as missing" do
    TestEnv.with_env(%{"MISTRAL_API_KEY" => "   "}, fn ->
      assert_raise RuntimeError,
                   "MISTRAL_API_KEY environment variable is required for Mistral API calls.",
                   fn -> OpenAI.client() end
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
end
