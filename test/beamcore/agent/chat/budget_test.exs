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

  test "prepares context with model metadata, tool schema, output reserve, and safety margin" do
    messages = [
      %{role: "system", content: "system"},
      %{role: "user", content: String.duplicate("a", 10_000)},
      %{role: "user", content: "latest"}
    ]

    metadata = %Beamcore.Provider.ModelMetadata{
      context_window: 2_000,
      max_output_tokens: 300,
      tokenizer: :chars_per_token_estimate,
      source: :config,
      accuracy: :reported
    }

    settings = %{input_budget: 5_000, output_budget: 1_000}
    tools = [%{function: %{name: "eeva", parameters: %{type: "object"}}}]

    assert {:ok, fitted, plan} = Budget.prepare_for_model(messages, tools, metadata, settings)

    assert plan.context_window == 2_000
    assert plan.context_source == :config
    assert plan.reserved_output_tokens == 300
    assert plan.tool_schema_tokens > 0
    assert plan.usable_input_budget < settings.input_budget
    assert plan.final_estimated_input_tokens <= plan.usable_input_budget
    assert plan.compacted
    assert Enum.any?(fitted, &(&1.content == "system"))
    assert Enum.any?(fitted, &(&1.content == "latest"))
  end

  test "unknown model context uses conservative mode budget and marks the source" do
    metadata = %Beamcore.Provider.ModelMetadata{source: :unknown, accuracy: :unknown}
    settings = %{input_budget: 800, output_budget: 100}

    assert {:ok, _messages, plan} =
             Budget.prepare_for_model([%{role: "user", content: "hello"}], [], metadata, settings)

    assert plan.context_window == nil
    assert plan.context_source == :unknown
    assert plan.safety_margin == 1_024
    assert plan.usable_input_budget == 800
  end
end
