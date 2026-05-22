defmodule Beamcore.Agent.Tools.CurlTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Curl

  test "curl requires a url parameter" do
    assert_raise KeyError, fn ->
      Curl.execute(%{})
    end
  end

  test "curl validates url protocol" do
    result = Curl.execute(%{"url" => "ftp://example.com"})
    assert result == "Error: URL must start with http:// or https://"
  end

  test "curl executes a valid get request" do
    # Using httpbin.org for testing HTTP responses
    result = Curl.execute(%{"url" => "https://httpbin.org/get"})

    assert String.contains?(result, "Status: 200")
    assert String.contains?(result, "<curl_metadata>")
  end
end
