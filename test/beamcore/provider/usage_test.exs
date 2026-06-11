defmodule Beamcore.Provider.UsageTest do
  use ExUnit.Case, async: true

  alias Beamcore.Provider.Usage

  test "normalizes OpenAI-compatible usage fields" do
    usage =
      Usage.from_response(%{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 4,
          "total_tokens" => 14,
          "prompt_tokens_details" => %{"cached_tokens" => 3},
          "completion_tokens_details" => %{"reasoning_tokens" => 2}
        }
      })

    assert usage.input_tokens == 10
    assert usage.output_tokens == 4
    assert usage.total_tokens == 14
    assert usage.cached_tokens == 3
    assert usage.reasoning_tokens == 2
    assert usage.source == :provider_reported
  end

  test "missing usage is explicit unknown" do
    assert %Usage{source: :unknown, total_tokens: nil} = Usage.from_response(%{})
  end

  test "provider usage can be converted to legacy session counters" do
    usage = %Usage{
      input_tokens: 7,
      output_tokens: 5,
      total_tokens: 12,
      source: :provider_reported
    }

    assert %{
             "prompt_tokens" => 7,
             "completion_tokens" => 5,
             "total_tokens" => 12
           } = Usage.to_raw_usage(usage)
  end
end
