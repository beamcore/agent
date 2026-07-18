defmodule Beamcore.Agent.Chat.LoopTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.Loop
  alias Beamcore.Agent.Tools.Dispatcher

  test "tool specs expose only eeva" do
    specs = Dispatcher.tool_specs()
    assert Enum.map(specs, & &1.function.name) == ["eeva"]
  end

  test "runtime system message is stable across turns" do
    tools = Dispatcher.tool_specs()
    messages = [%{role: "system", content: "stable system"}, %{role: "user", content: "one"}]

    first = Loop.ensure_runtime_message(messages, tools)
    second = Loop.ensure_runtime_message(first ++ [%{role: "assistant", content: "done"}], tools)

    assert Enum.take(second, length(first)) == first
    assert runtime_message_count(first) == 1
    assert runtime_message_count(second) == 1
  end

  test "runtime system message removes legacy duplicates once" do
    tools = Dispatcher.tool_specs()
    runtime = %{role: "system", content: "Exposed tools: old. Previous runtime message."}

    messages = [
      %{role: "system", content: "stable system"},
      runtime,
      runtime,
      %{role: "user", content: "continue"}
    ]

    cleaned = Loop.ensure_runtime_message(messages, tools)

    assert hd(cleaned) == hd(messages)
    assert runtime_message_count(cleaned) == 1
  end

  defp runtime_message_count(messages) do
    Enum.count(messages, fn message ->
      role = message[:role] || message["role"]
      content = message[:content] || message["content"] || ""
      role == "system" and String.starts_with?(content, "Exposed tools:")
    end)
  end
end
