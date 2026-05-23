defmodule Beamcore.Agent.Tools.ImageGenerationTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.ImageGeneration

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => "https://api.mistral.ai/v1",
      "MISTRAL_IMAGE_AGENT_ID" => nil,
      "MISTRAL_IMAGE_MODEL" => nil
    })

    File.rm_rf!("generated")

    on_exit(fn ->
      File.rm_rf!("generated")
      Process.delete(:mock_http_request)
    end)

    :ok
  end

  test "creates an image agent, starts a conversation, downloads the generated file" do
    png = tiny_png()

    Process.put(:mock_http_request, fn
      :post, {url, _headers, _content_type, body}, _http_opts, _opts ->
        url = to_string(url)
        decoded = Jason.decode!(body)

        cond do
          String.ends_with?(url, "/agents") ->
            assert decoded["tools"] == [%{"type" => "image_generation"}]
            {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(%{"id" => "agent_123"})}}

          String.ends_with?(url, "/conversations") ->
            assert decoded["agent_id"] == "agent_123"
            assert decoded["inputs"] =~ "terminal architecture"

            response = %{
              "outputs" => [
                %{
                  "type" => "message.output",
                  "content" => [
                    %{"type" => "text", "text" => "Generated."},
                    %{
                      "type" => "tool_file",
                      "tool" => "image_generation",
                      "file_id" => "file_123",
                      "file_name" => "image.png",
                      "file_type" => "png"
                    }
                  ]
                }
              ]
            }

            {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(response)}}
        end

      :get, {url, _headers}, _http_opts, _opts ->
        assert to_string(url) =~ "/files/file_123/content"
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], png}}
    end)

    result =
      ImageGeneration.execute(%{
        "prompt" => "Create a terminal architecture diagram.",
        "output_path" => "generated/terminal_architecture.png",
        "instructions" => "Use project context and generate a terminal architecture diagram."
      })

    assert {:ok, decoded} = Jason.decode(result)
    assert decoded["ok"] == true
    assert decoded["files"] == ["generated/terminal_architecture.png"]
    assert File.read!("generated/terminal_architecture.png") == png
  end

  test "can reuse an existing image agent id" do
    png = tiny_png()

    Beamcore.Agent.TestEnv.with_env(%{"MISTRAL_IMAGE_AGENT_ID" => "agent_existing"}, fn ->
      Process.put(:mock_http_request, fn
        :post, {url, _headers, _content_type, body}, _http_opts, _opts ->
          refute String.ends_with?(to_string(url), "/agents")
          decoded = Jason.decode!(body)
          assert decoded["agent_id"] == "agent_existing"

          response = %{
            "outputs" => [
              %{
                "content" => [
                  %{"type" => "tool_file", "file_id" => "file_456", "file_type" => "png"}
                ]
              }
            ]
          }

          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(response)}}

        :get, {url, _headers}, _http_opts, _opts ->
          assert to_string(url) =~ "/files/file_456/content"
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], png}}
      end)

      result =
        ImageGeneration.execute(%{
          "prompt" => "Create a simple image.",
          "output_path" => "generated/reused_agent.png"
        })

      assert {:ok, decoded} = Jason.decode(result)
      assert decoded["ok"] == true
      assert decoded["files"] == ["generated/reused_agent.png"]
      assert File.read!("generated/reused_agent.png") == png
    end)
  end

  test "rejects unsafe output paths" do
    result =
      ImageGeneration.execute(%{
        "prompt" => "Create an image.",
        "output_path" => "../outside.png"
      })

    assert result =~ "Error:"
    assert result =~ "path traversal is not allowed"
  end

  test "rejects non-image downloaded payloads" do
    Process.put(:mock_http_request, fn
      :post, {url, _headers, _content_type, body}, _http_opts, _opts ->
        decoded = Jason.decode!(body)

        cond do
          String.ends_with?(to_string(url), "/agents") ->
            {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(%{"id" => "agent_123"})}}

          String.ends_with?(to_string(url), "/conversations") ->
            assert decoded["agent_id"] == "agent_123"

            response = %{
              "outputs" => [
                %{
                  "content" => [
                    %{"type" => "tool_file", "file_id" => "file_bad", "file_type" => "png"}
                  ]
                }
              ]
            }

            {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(response)}}
        end

      :get, {url, _headers}, _http_opts, _opts ->
        assert to_string(url) =~ "/files/file_bad/content"
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], String.duplicate("not an image payload ", 4)}}
    end)

    result =
      ImageGeneration.execute(%{
        "prompt" => "Create a simple image.",
        "output_path" => "generated/bad.png"
      })

    assert result =~ "Error:"
    assert result =~ "is not a valid image payload"
    refute File.exists?("generated/bad.png")
  end

  defp tiny_png do
    <<
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82
    >>
  end
end
