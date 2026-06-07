defmodule Beamcore.Agent.Chat.SearchConductorTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.SearchConductor
  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Provider.OllamaDiscovery
  alias Beamcore.Agent.TestEnv

  setup do
    Process.delete(:mock_completions_create)
    Process.delete(:mock_http_request)

    client = OpenaiEx.new("test-key")
    session = Session.new(client, workspace_root: ".")

    {:ok, session: session}
  end

  test "Ollama discovery matches model via OpenAI-compatible models endpoint", %{
    session: _session
  } do
    Process.put(:mock_http_request, fn _method, request, _http_opts, _opts ->
      url_chars = elem(request, 0)
      url_str = to_string(url_chars)

      cond do
        String.contains?(url_str, "/models") ->
          {:ok,
           {
             {~c"HTTP/1.1", 200, ~c"OK"},
             [],
             Jason.encode!(%{
               "data" => [
                 %{"id" => "gemma4:latest"},
                 %{"id" => "functiongemma:latest"}
               ]
             })
           }}

        true ->
          {:error, :not_found}
      end
    end)

    assert OllamaDiscovery.check_availability(
             "http://127.0.0.1:11434/v1",
             "functiongemma:latest"
           )

    assert OllamaDiscovery.check_availability("http://127.0.0.1:11434/v1", "gemma4:latest")
    refute OllamaDiscovery.check_availability("http://127.0.0.1:11434/v1", "nonexistent:latest")
  end

  test "Ollama discovery falls back to native /api/tags endpoint", %{session: _session} do
    Process.put(:mock_http_request, fn _method, request, _http_opts, _opts ->
      url_chars = elem(request, 0)
      url_str = to_string(url_chars)

      cond do
        String.contains?(url_str, "/models") ->
          # Return 404/error to force fallback
          {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], ""}}

        String.contains?(url_str, "/api/tags") ->
          {:ok,
           {
             {~c"HTTP/1.1", 200, ~c"OK"},
             [],
             Jason.encode!(%{
               "models" => [
                 %{"name" => "functiongemma:latest"}
               ]
             })
           }}

        true ->
          {:error, :not_found}
      end
    end)

    assert OllamaDiscovery.check_availability(
             "http://127.0.0.1:11434/v1",
             "functiongemma:latest"
           )

    refute OllamaDiscovery.check_availability("http://127.0.0.1:11434/v1", "gemma4:latest")
  end

  test "preflight/5 does not contact a helper unless the user enabled one", %{session: session} do
    Process.put(:mock_completions_create, fn _client, _params ->
      flunk("helper should not be called while disabled")
    end)

    messages = session.messages

    {updated_messages, updated_session} =
      SearchConductor.preflight(
        session,
        messages,
        "find policy code",
        ToolPolicy.default(),
        silent: true
      )

    assert updated_messages == messages
    assert updated_session == session
  end

  test "preflight/5 returns unmodified state if conductor is disabled", %{session: session} do
    TestEnv.with_env(%{"BEAMCORE_SEARCH_CONDUCTOR" => "false"}, fn ->
      messages = session.messages

      {updated_messages, updated_session} =
        SearchConductor.preflight(session, messages, "hello", ToolPolicy.default())

      assert updated_messages == messages
      assert updated_session == session
    end)
  end

  test "preflight/5 uses the exact helper model explicitly selected by the user", %{
    session: session
  } do
    TestEnv.with_env(%{"OLLAMA_MODEL" => nil, "BEAMCORE_OLLAMA_MODEL" => nil}, fn ->
      selected_model = "qwen2.5-coder:latest"
      session = Session.set_helper_provider(session, "ollama", selected_model)

      # 1. Stub HTTP calls to claim the selected model is available
      mock_fun = fn _method, request, _http_opts, _opts ->
        url_chars = elem(request, 0)
        url_str = to_string(url_chars)

        cond do
          String.contains?(url_str, "/models") ->
            {:ok,
             {
               {~c"HTTP/1.1", 200, ~c"OK"},
               [],
               Jason.encode!(%{
                 "data" => [
                   %{"id" => selected_model}
                 ]
               })
             }}

          true ->
            {:error, :not_found}
        end
      end

      Application.put_env(:agent, :global_mock_http_request, mock_fun)
      Process.put(:mock_http_request, mock_fun)

      on_exit(fn ->
        Application.delete_env(:agent, :global_mock_http_request)
      end)

      # 2. Stub Completions call to return a tool call to grep
      Process.put(:mock_completions_create, fn _client, params ->
        assert params.model == selected_model

        {:ok,
         %{
           "choices" => [
             %{
               "message" => %{
                 "role" => "assistant",
                 "content" => "",
                 "tool_calls" => [
                   %{
                     "id" => "call_grep_1",
                     "type" => "function",
                     "function" => %{
                       "name" => "grep",
                       "arguments" => Jason.encode!(%{"pattern" => "policy", "path" => "lib"})
                     }
                   }
                 ]
               }
             }
           ]
         }}
      end)

      messages = session.messages ++ [%{role: "user", content: "search for policy code in lib"}]

      # We must mock output and event handler to avoid printing/crashing
      opts = [
        silent: true,
        event_handler: fn _event -> :ok end
      ]

      {updated_messages, updated_session} =
        SearchConductor.preflight(
          session,
          messages,
          "search for policy code in lib",
          ToolPolicy.default(),
          opts
        )

      # The messages list should now contain:
      # 1. System instruction
      # 2. User prompt
      # 3. Assistant message with tool_calls
      # 4. Tool response message
      assert length(updated_messages) == length(messages) + 2

      assistant_msg = Enum.at(updated_messages, -2)
      assert assistant_msg["role"] == "assistant"
      assert is_list(assistant_msg["tool_calls"])

      tool_msg = Enum.at(updated_messages, -1)
      assert tool_msg.role == "tool"
      assert tool_msg.name == "grep"
      assert tool_msg.tool_call_id == "call_grep_1"

      # Context should be updated (inspected_files should track searched area)
      assert MapSet.member?(updated_session.context.inspected_files, "lib")
    end)
  end
end
