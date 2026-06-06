defmodule Beamcore.Provider.RouterTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.Router

  setup do
    path =
      Path.join(System.tmp_dir!(), "beamcore_router_#{System.unique_integer([:positive])}.dets")

    previous_path = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-mistral-key",
      "MISTRAL_BASE_URL" => nil,
      "API_KEY" => nil,
      "ACTIVE_PROVIDER" => nil
    })

    on_exit(fn ->
      restore_config_path(previous_path)
      File.rm(path)
      Process.delete(:mock_completions_create)
    end)

    :ok
  end

  test "routes Mistral chat through the registry-selected compatible adapter" do
    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "mistral", model: "mistral-medium-3-5"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:call, "https://api.mistral.ai/v1", "test-mistral-key", "mistral-medium-3-5"}
  end

  test "routes Ollama chat through compatible /v1 without requiring an API key" do
    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "local"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "local"}}]}} =
             Router.chat(
               %{provider: "ollama", model: "gemma4:latest"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:call, "http://127.0.0.1:11434/v1", "unused", "gemma4:latest"}
  end

  test "routes a custom compatible provider without adding an adapter module" do
    assert :ok =
             Beamcore.Config.put_provider("custom-compatible", %{
               api_key: "secret",
               base_url: "https://compatible.example/v1",
               default_model: "model-a"
             })

    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "custom-compatible", model: "model-a"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:call, "https://compatible.example/v1", "secret", "model-a"}
  end

  test "returns typed error for unsupported provider selection" do
    assert {:error, %Beamcore.Provider.Error{kind: :invalid_config}} =
             Router.chat(
               %{provider: "missing-provider", model: "model"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )
  end

  test "router does not contain provider-brand adapter mappings" do
    source = File.read!(Path.expand("../../../lib/beamcore/provider/router.ex", __DIR__))

    refute source =~ "@adapters"
    refute source =~ ~s("mistral" =>)
    refute source =~ ~s("ollama" =>)
    refute source =~ "Beamcore.Provider.Mistral"
    refute source =~ "Beamcore.Provider.Ollama"
    refute source =~ "Beamcore.Provider.Generic"
  end

  test "OpenAI-compatible adapter does not hardcode provider identity maps" do
    source =
      File.read!(
        Path.expand(
          "../../../lib/beamcore/provider/adapters/openai_compatible.ex",
          __DIR__
        )
      )

    refute source =~ "provider_atom"
    refute source =~ ~s("mistral")
    refute source =~ ~s("ollama")
    refute source =~ ~s("openai")
    refute source =~ ~s("deepseek")
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end
