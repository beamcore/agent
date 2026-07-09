defmodule Beamcore.Agent.Chat.ModelPayloadTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.{Budget, ModelPayload}

  test "limits long tool result fields while keeping valid JSON" do
    content =
      Jason.encode!(%{
        "ok" => true,
        "tool" => "eeva",
        "summary" => "read file",
        "stdout" => String.duplicate("stdout\n", 3_000),
        "stderr" => "",
        "result" => "HEAD\n" <> String.duplicate("body\n", 12_000) <> "TAIL"
      })

    [limited] =
      ModelPayload.limit(
        [%{role: "tool", tool_call_id: "call_1", name: "eeva", content: content}],
        %{context_window: 8_000}
      )

    decoded = Jason.decode!(limited.content)

    assert decoded["ok"]
    assert decoded["summary"] == "read file"
    assert decoded["_beamcore_model_payload_limited"]
    assert decoded["stdout"] =~ "stdout"
    assert decoded["result"] =~ "HEAD"
    assert decoded["result"] =~ "TAIL"
    assert decoded["result"] =~ "truncated for model context"
    assert String.length(decoded["result"]) < String.length(Jason.decode!(content)["result"])
  end

  test "limits large assistant tool arguments but preserves tool call shape" do
    full_code =
      "File.write!(\"lib/big.ex\", ~S'''\n" <>
        String.duplicate("def x, do: :ok\n", 6_000) <>
        "''')"

    arguments = Jason.encode!(%{"code" => full_code})

    [limited] =
      ModelPayload.limit(
        [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "eeva", "arguments" => arguments}
              }
            ]
          }
        ],
        %{context_window: 8_000}
      )

    [tool_call] = limited.tool_calls
    decoded_args = Jason.decode!(tool_call["function"]["arguments"])

    assert tool_call["id"] == "call_1"
    assert tool_call["function"]["name"] == "eeva"
    assert decoded_args["_beamcore_model_payload_limited"]
    assert decoded_args["code"] =~ "File.write!"
    assert decoded_args["code"] =~ "truncated for model context"
    assert String.length(decoded_args["code"]) < String.length(full_code)
  end

  test "keeps session freedom by returning a bounded copy instead of mutating the input" do
    original = [
      %{role: "user", content: String.duplicate("u", 80_000)}
    ]

    [limited] = ModelPayload.limit(original, %{context_window: 8_000})

    assert hd(original).content == String.duplicate("u", 80_000)
    assert limited.content =~ "truncated for model context"
    assert String.length(limited.content) < String.length(hd(original).content)
  end

  test "compacts older messages when total payload exceeds the provider budget" do
    older =
      for index <- 1..12 do
        %{role: "user", content: "old #{index} " <> String.duplicate("x", 20_000)}
      end

    latest = %{role: "user", content: "latest instruction must stay verbatim"}
    messages = [%{role: "system", content: "sys"}] ++ older ++ [latest]

    limited = ModelPayload.limit(messages, %{context_window: 4_000})

    assert List.last(limited).content == latest.content
    assert Budget.estimate_tokens(limited) < Budget.estimate_tokens(messages)

    assert Enum.any?(limited, fn msg ->
             is_binary(msg.content) and String.contains?(msg.content, "older message content")
           end)
  end
end
