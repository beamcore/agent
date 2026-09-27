defmodule Beamcore.Agent.SubAgentTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.SubAgent
  alias Beamcore.Agent.Tools.Dispatcher

  test "get_tools filters by tool name" do
    assert SubAgent.get_tools(true) == Dispatcher.tool_specs()
    assert Enum.map(SubAgent.get_tools(["eeva"]), & &1.function.name) == ["eeva"]
    assert SubAgent.get_tools(["no_such_tool"]) == []
  end

  test "limits historical payloads while preserving executable code" do
    code = "WriteHelper.write!(\"large.ex\", eeva_payloads[\"content\"])"
    payload = String.duplicate("generated code\n", 8_000)

    tool_call = %{
      "id" => "call_1",
      "type" => "function",
      "function" => %{
        "name" => "eeva",
        "arguments" => Jason.encode!(%{"code" => code, "payloads" => %{"content" => payload}})
      }
    }

    messages = [
      %{role: "system", content: "system"},
      %{role: "user", content: "generate"},
      %{role: "assistant", content: nil, tool_calls: [tool_call]},
      %{role: "tool", tool_call_id: "call_1", content: Jason.encode!(%{"ok" => true})}
    ]

    prepared =
      SubAgent.prepare_messages(%{provider: "openai", model: "gpt-4o"}, messages)

    sent_call = prepared |> Enum.at(2) |> Map.fetch!(:tool_calls) |> hd()
    args = sent_call |> get_in(["function", "arguments"]) |> Jason.decode!()

    assert args["code"] == code
    assert args["payloads"]["content"] =~ "truncated for model context"
    assert String.length(args["payloads"]["content"]) < String.length(payload)
  end
end
