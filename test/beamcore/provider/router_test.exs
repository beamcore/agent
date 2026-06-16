defmodule Beamcore.Provider.RouterTest do
  use ExUnit.Case, async: false

  alias Beamcore.Provider.Router

  setup do
    path =
      Path.join(System.tmp_dir!(), "beamcore_router_#{System.unique_integer([:positive])}.dets")

    previous_path = Application.get_env(:agent, :config_dets_path)
    Application.put_env(:agent, :config_dets_path, path)

    Beamcore.Config.put_provider("openai", %{
      api_key: "test-openai-key",
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o"
    })

    on_exit(fn ->
      restore_config_path(previous_path)
      File.rm(path)
      Process.delete(:mock_completions_create)
    end)

    :ok
  end

  test "routes OpenAI chat through the registry-selected compatible adapter" do
    parent = self()

    Process.put(:mock_completions_create, fn client, params ->
      send(parent, {:call, client.base_url, client.token, params.model})
      {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
    end)

    assert {:ok, %{"choices" => [%{"message" => %{"content" => "ok"}}]}} =
             Router.chat(
               %{provider: "openai", model: "gpt-4o"},
               %{messages: [%{role: "user", content: "hi"}], tools: []}
             )

    assert_receive {:call, "https://api.openai.com/v1", "test-openai-key", "gpt-4o"}
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
    refute source =~ ~s("ollama")
    refute source =~ ~s("openai")
    refute source =~ ~s("deepseek")
  end

  defp restore_config_path(nil), do: Application.delete_env(:agent, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:agent, :config_dets_path, path)
end
