defmodule Beamcore.Agent.Chat.BudgetTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.Budget

  test "fits messages to an approximate token budget" do
    messages = [
      %{role: "system", content: "system"},
      %{role: "user", content: "old " <> String.duplicate("a", 4_000)},
      %{role: "assistant", content: String.duplicate("b", 4_000)},
      %{role: "user", content: "latest request"}
    ]

    fitted = Budget.fit_messages(messages, 300)

    assert Budget.estimate_tokens(fitted) <= 300
    assert Enum.any?(fitted, &(&1.content == "system"))
    assert Enum.any?(fitted, &(&1.content == "latest request"))
  end

  test "compact_text keeps head and tail" do
    text = "HEAD" <> String.duplicate("x", 1_000) <> "TAIL"

    compacted = Budget.compact_text(text, 120)

    assert String.starts_with?(compacted, "HEAD")
    assert String.ends_with?(compacted, "TAIL")
    assert compacted =~ "[omitted"
  end
end
