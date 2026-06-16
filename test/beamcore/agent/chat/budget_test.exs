defmodule Beamcore.Agent.Chat.BudgetTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.Budget

  test "estimates tokens from messages" do
    messages = [
      %{role: "system", content: "hello"},
      %{role: "user", content: String.duplicate("a", 400)}
    ]

    estimate = Budget.estimate_tokens(messages)

    # "hello" = 5 chars, 400 a's = 400 chars, total 405 chars / 4 = 101
    assert estimate == 101
  end

  test "counts tool_calls in estimate" do
    messages = [
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: "call_1", function: %{name: "test", arguments: "{}"}}]
      }
    ]

    estimate = Budget.estimate_tokens(messages)
    assert estimate > 0
  end

  test "returns 0 for empty messages" do
    assert Budget.estimate_tokens([]) == 0
  end

  test "handles nil content" do
    messages = [%{role: "assistant", content: nil}]
    assert Budget.estimate_tokens(messages) == 0
  end
end
