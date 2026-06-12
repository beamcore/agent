defmodule Beamcore.Agent.MockCompletions do
  def create(client, params) do
    case Process.get(:mock_completions_create) ||
           Application.get_env(:agent, :mock_completions_create) do
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
    mock_fun =
      Process.get(:mock_http_request) || Application.get_env(:agent, :global_mock_http_request)

    case mock_fun do
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

defmodule Beamcore.Agent.TestEnv do
  def setup_env(env) do
    previous = snapshot(Map.keys(env))
    apply_env(env)

    ExUnit.Callbacks.on_exit(fn ->
      restore(previous)
    end)

    :ok
  end

  def with_env(env, fun) do
    previous = snapshot(Map.keys(env))
    apply_env(env)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp snapshot(names) do
    Map.new(names, fn name -> {name, System.get_env(name)} end)
  end

  defp apply_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp restore(env) do
    apply_env(env)
  end
end
