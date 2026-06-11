defmodule Beamcore.Agent.Chat.RateLimitTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.RateLimit

  test "parses retry-after seconds from provider body" do
    error = %OpenaiEx.Error{
      kind: :rate_limit,
      status_code: 429,
      body: %{"retry_after" => "12"}
    }

    assert RateLimit.retry_after_seconds(error) == 12
    assert RateLimit.retry_after_ms(error) == 12_000
    assert RateLimit.message(error) =~ "12 seconds"
  end

  test "parses retry-after seconds from provider message" do
    error = %OpenaiEx.Error{
      kind: :rate_limit,
      status_code: 429,
      message: "Too many requests. Retry-After: 9"
    }

    assert RateLimit.retry_after_seconds(error) == 9
  end

  test "formats generic provider rate limit without retry-after metadata" do
    error = %OpenaiEx.Error{kind: :rate_limit, status_code: 429}

    assert RateLimit.retry_after_seconds(error) == nil
    assert RateLimit.message(error) == "Provider rate limit reached. Wait a bit, then retry."
  end
end
