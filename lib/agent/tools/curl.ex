defmodule Beamcore.Agent.Tools.Curl do
  @moduledoc """
  Tool to fetch content from URLs using HTTP requests.
  """

  @description """
  Fetch content from a URL via HTTP GET, POST, PUT, DELETE, or PATCH methods.
  Supports custom headers, request bodies, and custom timeouts for web resource access.
  Returns the response body, HTTP status code, and all returned response headers.
  """

  @max_bytes 2_000_000
  @timeout 30_000

  def name, do: "curl"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            url: %{
              type: "string",
              description: "The URL to fetch. Must start with http:// or https://."
            },
            method: %{
              type: "string",
              enum: ["GET", "POST", "PUT", "DELETE", "PATCH"],
              description: "HTTP method to use. Defaults to GET."
            },
            headers: %{
              type: "object",
              additionalProperties: %{type: "string"},
              description:
                "Dictionary of HTTP headers (e.g., {\"Accept\": \"application/json\"})."
            },
            body: %{
              type: "string",
              description: "Request body for POST, PUT, or PATCH requests."
            },
            timeout: %{
              type: "integer",
              description: "Timeout in milliseconds. Defaults to 30000 (30 seconds)."
            }
          },
          required: ["url"]
        }
      }
    }
  end

  def execute(params) do
    url = Map.fetch!(params, "url")
    method = Map.get(params, "method", "GET") |> String.upcase()
    headers = Map.get(params, "headers", %{})
    body = Map.get(params, "body")
    timeout = Map.get(params, "timeout", @timeout)

    # Validate URL
    if String.starts_with?(url, "http://") || String.starts_with?(url, "https://") do
      header_list =
        Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

      method_atom = method |> String.downcase() |> String.to_atom()

      make_request(method_atom, url, header_list, body, timeout)
    else
      "Error: URL must start with http:// or https://"
    end
  end

  defp make_request(method, url, headers, body, timeout) do
    :inets.start()
    :ssl.start()

    request =
      if method in [:get, :delete] do
        {String.to_charlist(url), headers}
      else
        content_type =
          Enum.find_value(headers, "text/plain", fn {k, v} ->
            if String.downcase(to_string(k)) == "content-type", do: v
          end)

        {String.to_charlist(url), headers, content_type, body || ""}
      end

    http_opts = [timeout: timeout, autoredirect: true]

    case http_client().request(method, request, http_opts, []) do
      {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
        body_str = IO.iodata_to_binary(resp_body)

        body_str =
          if byte_size(body_str) > @max_bytes do
            truncated_body = binary_part(body_str, 0, @max_bytes)
            truncated_body <> "\n\n... (response truncated to #{@max_bytes} bytes)"
          else
            body_str
          end

        formatted_headers =
          Enum.map(resp_headers, fn {key, value} ->
            "#{key}: #{value}"
          end)
          |> Enum.join(", ")

        metadata_str = "Status: #{status}, Headers: #{formatted_headers}"

        """
        #{body_str}

        <curl_metadata>
        #{metadata_str}
        </curl_metadata>
        """

      {:error, reason} ->
        "Error: #{inspect(reason)}"
    end
  end

  defp http_client do
    Application.get_env(:agent, :http_client, Beamcore.Agent.Tools.Curl.HTTPCWrapper)
  end
end

defmodule Beamcore.Agent.Tools.Curl.HTTPCWrapper do
  @moduledoc """
  Production HTTP client wrapper for :httpc.
  """
  def request(method, request, http_opts, opts) do
    :httpc.request(method, request, http_opts, opts)
  end
end
