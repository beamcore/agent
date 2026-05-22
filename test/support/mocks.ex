defmodule Beamcore.Agent.MockCompletions do
  def create(client, params) do
    case Process.get(:mock_completions_create) do
      nil ->
        # Default mock response for general completions
        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => "This is a mock assistant response."
               }
             }
           ]
         }}

      fun when is_function(fun) ->
        fun.(client, params)
    end
  end
end

defmodule Beamcore.Agent.MockHTTPClient do
  def request(method, request, http_opts, opts) do
    case Process.get(:mock_http_request) do
      nil ->
        # Decode the request URL
        url_chars =
          case request do
            {u, _h} -> u
            {u, _h, _ct, _b} -> u
          end

        url_str = to_string(url_chars)

        cond do
          String.contains?(url_str, "httpbin.org/get") ->
            {:ok,
             {
               {~c"HTTP/1.1", 200, ~c"OK"},
               [{~c"content-type", ~c"application/json"}],
               "{\n  \"args\": {},\n  \"headers\": {\n    \"Host\": \"httpbin.org\"\n  },\n  \"url\": \"https://httpbin.org/get\"\n}\n"
             }}

          true ->
            {:ok,
             {
               {~c"HTTP/1.1", 200, ~c"OK"},
               [],
               "Mock response for " <> url_str
             }}
        end

      fun when is_function(fun) ->
        fun.(method, request, http_opts, opts)
    end
  end
end
