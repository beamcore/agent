defmodule Beamcore.Agent.MockCompletions do
  def create(client, params) do
    create(client, params, [])
  end

  def create(client, params, _opts) do
    case Process.get(:mock_completions_create) ||
           Application.get_env(:beamcore, :mock_completions_create) do
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

defmodule Beamcore.Provider.AuthHTTPMock do
  def post(url, opts) do
    send(Process.get(:auth_test_pid, self()), {:oauth_post, url, opts})

    case Process.get(:auth_http_responses) do
      [response | rest] ->
        Process.put(:auth_http_responses, rest)
        response

      response ->
        response ||
          {:ok, %{status: 200, body: %{"access_token" => "oauth-token", "expires_in" => 3600}}}
    end
  end
end

defmodule Beamcore.Provider.CompatibleHTTPMock do
  def post(url, opts) do
    send(Process.get(:compatible_test_pid, self()), {:compatible_post, url, opts})

    case Process.get(:compatible_http_responses) do
      [response | rest] ->
        Process.put(:compatible_http_responses, rest)
        response

      response when not is_nil(response) ->
        response

      nil ->
        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}
         }}
    end
  end
end
