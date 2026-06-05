defmodule Beamcore.Agent.Chat.SearchConductor do
  @moduledoc """
  Pre-flight workspace search conductor.
  Uses a local, fast model (like FunctionGemma or Gemma4 via Ollama) to pre-fetch context
  before invoking the main, large reasoning model.
  """

  alias Beamcore.Agent.Chat.Context
  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Core.Pretty
  alias Beamcore.Agent.Tools.Dispatcher

  require Logger

  @http_client Application.compile_env(:agent, :http_client, :httpc)
  @completions_module Application.compile_env(
                        :agent,
                        :completions_module,
                        OpenaiEx.Chat.Completions
                      )
  @default_base_url "http://127.0.0.1:11434/v1"
  @model_search_order ["functiongemma:latest", "gemma4:latest", "gemma:latest", "gemma:2b"]
  @search_tools ["grep", "glob", "tree", "read"]

  @system_prompt """
  You are a pre-flight search assistant for a coding agent.
  Your ONLY job is to analyze the user request and determine if search or directory traversal tools are needed to find relevant code or files before the main coding agent answers.

  You have access to the following tools:
  - `glob` (parameters: `pattern` [required], `path` [optional], `all` [optional]): Find workspace files matching a pattern.
  - `grep` (parameters: `pattern` [required], `path` [optional], `include` [optional]): Search file contents for a regex pattern.
  - `tree` (parameters: `path` [optional]): Show a compact directory tree.
  - `read` (parameters: `filePath` [required], `offset` [optional], `limit` [optional]): Read the content of a file or directory.

  CRITICAL GUIDELINES:
  1. If the user asks about the existence, location, or structure of files/workflows (e.g. "where are the github actions?", "find the config files", "list files in test/"), call `glob` or `tree`.
  2. If the user asks to find references, definitions, or code patterns in files (e.g. "where is SearchConductor defined?", "find all mentions of HTTP client"), call `grep`.
  3. If the user references a specific file to examine or read (e.g. "show me loop.ex", "view search_conductor.ex"), call `read`.
  4. If the user's message is a greeting, general conversation, or describes instructions for code edits/actions without asking to find or inspect files (e.g. "lets do prompt adjustment first, than figure out how to tune it", "hello", "write a test for this function"), do NOT call any tools and reply with a brief text.

  EXAMPLES:

  Example 1:
  User: where are the github actions?
  Tool Call: glob(pattern: ".github/workflows/*")

  Example 2:
  User: find all references to SearchConductor
  Tool Call: grep(pattern: "SearchConductor")

  Example 3:
  User: read the dispatcher.ex file
  Tool Call: read(filePath: "lib/agent/tools/dispatcher.ex")

  Example 4:
  User: show me the workspace layout
  Tool Call: tree(path: ".")

  Example 5:
  User: lets do prompt adjustment first, than figure out how to tune it
  Response: Okay, let's proceed with prompt adjustments. No search needed.
  """


  @doc """
  Performs pre-flight workspace search if Ollama and a suitable model are available.
  Returns the updated session with search messages and updated context.
  """
  def preflight(session, messages, content, policy, opts \\ []) do
    # Only run search conductor if enabled in environment (default is true)
    if System.get_env("BEAMCORE_SEARCH_CONDUCTOR") == "false" do
      {messages, session}
    else
      base_url =
        System.get_env("OLLAMA_BASE_URL") || System.get_env("BEAMCORE_OLLAMA_BASE_URL") ||
          @default_base_url

      case detect_model(base_url) do
        {:ok, model} ->
          run_preflight(session, messages, content, model, base_url, policy, opts)

        _ ->
          # Silently fallback to main reasoning flow
          {messages, session}
      end
    end
  end

  # Helper to query Ollama for model availability
  def check_availability(base_url, model) do
    base_url = String.trim_trailing(base_url, "/")

    # Try OpenAI-compatible /models endpoint
    case get_request("#{base_url}/models") do
      {:ok, %{"data" => models}} when is_list(models) ->
        Enum.any?(models, fn m -> m["id"] == model end)

      _ ->
        # Fallback to Ollama native /api/tags
        root_url = String.replace(base_url, ~r|/v1$|, "")

        case get_request("#{root_url}/api/tags") do
          {:ok, %{"models" => models}} when is_list(models) ->
            Enum.any?(models, fn m -> m["name"] == model end)

          _ ->
            false
        end
    end
  end

  defp detect_model(base_url) do
    case System.get_env("OLLAMA_MODEL") || System.get_env("BEAMCORE_OLLAMA_MODEL") do
      model when is_binary(model) and model != "" ->
        if check_availability(base_url, model), do: {:ok, model}, else: {:error, :not_found}

      _ ->
        # Try search order
        active_model =
          Enum.find(@model_search_order, fn candidate ->
            check_availability(base_url, candidate)
          end)

        if active_model, do: {:ok, active_model}, else: {:error, :not_found}
    end
  end

  defp get_request(url) do
    request = {to_charlist(url), []}

    case @http_client.request(:get, request, [timeout: 300], []) do
      {:ok, {{_http, status, _reason}, _headers, body}} when status in 200..299 ->
        Jason.decode(normalize_body(body))

      _ ->
        {:error, :failed}
    end
  end

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp normalize_body(body), do: IO.iodata_to_binary(body)

  defp run_preflight(session, messages, content, model, base_url, policy, opts) do
    tools = search_tool_specs(policy)

    if Enum.empty?(tools) do
      {messages, session}
    else
      client =
        OpenaiEx.new("ollama")
        |> OpenaiEx.with_base_url(base_url)
        |> OpenaiEx.with_receive_timeout(5000)

      preflight_prompt_messages = [
        %{role: "system", content: @system_prompt},
        %{role: "user", content: content}
      ]

      # Indicate to TUI and console that local search is starting
      emit(opts, {:status, :local_search})
      emit(opts, {:local_info, "Checking workspace search needs via local model (#{model})..."})

      maybe_print(opts, fn ->
        IO.puts(
          IO.ANSI.cyan() <>
            "* Ollama (#{model}) -> checking workspace search needs..." <> IO.ANSI.reset()
        )
      end)

      # Call Ollama completions
      res =
        @completions_module.create(client, %{
          model: model,
          messages: preflight_prompt_messages,
          tools: tools
        })

      case res do
        {:ok, %{"choices" => [%{"message" => assistant_message} | _]}} ->
          if has_tool_calls?(assistant_message) do
            emit(opts, {:local_info, "Local search tools detected. Running local pre-flight..."})
            execute_preflight_tools(session, messages, assistant_message, policy, opts)
          else
            emit(opts, {:local_info, "No search tools needed."})
            emit(opts, {:status, :thinking})
            {messages, session}
          end

        error ->
          emit(opts, {:local_info, "Failed to query local model."})
          emit(opts, {:status, :thinking})
          Logger.debug("Ollama pre-flight completions call failed: #{inspect(error)}")
          {messages, session}
      end
    end
  end

  defp search_tool_specs(policy) do
    allowed_names = ToolPolicy.allowed_tool_names(policy)

    Dispatcher.tool_specs(policy)
    |> Enum.filter(fn spec ->
      name = get_in(spec, [:function, :name]) || get_in(spec, ["function", "name"])
      name in @search_tools and name in allowed_names
    end)
  end

  defp has_tool_calls?(%{"tool_calls" => tool_calls}) when is_list(tool_calls),
    do: tool_calls != []

  defp has_tool_calls?(_message), do: false

  defp execute_preflight_tools(session, messages, assistant_message, policy, opts) do
    # Normalize tool calls
    assistant_message = normalize_tool_calls(assistant_message)
    session = Beamcore.Agent.Chat.Session.log(session, assistant_message)

    # Execute each search tool call
    {tool_responses, session} =
      Enum.map_reduce(assistant_message["tool_calls"], session, fn tool_call, session ->
        name = tool_call["function"]["name"]
        args = decode_tool_args(tool_call["function"]["arguments"])
        local_name = "[local] " <> name

        emit(opts, {:tool_queued, local_name, args})
        emit(opts, {:status, :tool_running})
        emit(opts, {:tool_running, local_name, args})

        # Run tool locally via dispatcher
        content = Dispatcher.execute(name, args, policy)
        maybe_print(opts, fn -> print_tool_execution(name, args, content) end)
        event_content = compact_event_content(content)
        emit(opts, {:tool_finished, local_name, args, event_content})

        session = %{
          session
          | context: Context.update_from_tool(session.context, name, args, content)
        }

        emit(opts, {:session, session})

        response_msg = %{
          role: "tool",
          tool_call_id: tool_call["id"],
          name: name,
          content: content
        }

        {response_msg, session}
      end)

    Enum.each(tool_responses, &Beamcore.Agent.Chat.Session.log(session, &1))

    emit(opts, {:local_info, "Local pre-flight search completed. Context pre-fetched."})

    maybe_print(opts, fn ->
      IO.puts(IO.ANSI.cyan() <> "* Ollama -> pre-flight search completed." <> IO.ANSI.reset())
    end)

    # Restore status to thinking for the main reasoning loop
    emit(opts, {:status, :thinking})

    # Append tool calls and responses to the messages list
    updated_messages = messages ++ [assistant_message] ++ tool_responses
    {updated_messages, session}
  end

  defp normalize_tool_calls(%{"tool_calls" => tool_calls} = message) when is_list(tool_calls) do
    fixed =
      Enum.map(tool_calls, fn tc ->
        tc |> Map.put("type", "function") |> Map.delete("index")
      end)

    Map.put(message, "tool_calls", fixed)
  end

  defp normalize_tool_calls(message), do: message

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_args), do: %{}

  defp emit(opts, event) do
    case Keyword.get(opts, :event_handler) do
      handler when is_function(handler, 1) ->
        try do
          handler.(event)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      nil ->
        :ok
    end
  end

  defp maybe_print(opts, fun) do
    unless Keyword.get(opts, :silent, false), do: fun.()
  end

  defp print_tool_execution(name, args, "Error: Tool call blocked" <> rest) do
    Pretty.print_blocked_tool_call(name, args, "Tool call blocked" <> rest)
  end

  defp print_tool_execution(name, args, "Error: Mutation requires" <> rest) do
    Pretty.print_blocked_tool_call(name, args, "Mutation requires" <> rest)
  end

  defp print_tool_execution(name, args, "Error: " <> reason) do
    Pretty.print_tool_call(name, args)
    Pretty.print_error(reason)
  end

  defp print_tool_execution(name, args, _content) do
    # Add a custom prefix to indicate local pre-flight search
    Pretty.print_tool_call("[local pre-flight] " <> name, args)
  end

  defp compact_event_content(content) when is_binary(content) do
    limit = 1200
    head = 420
    tail = 260

    if String.length(content) <= limit do
      content
    else
      char_count = String.length(content)
      line_count = content |> String.split("\n") |> length()
      omitted = max(char_count - head - tail, 0)
      h = String.slice(content, 0, head)
      t = String.slice(content, char_count - tail, tail)

      """
      #{h}

      [tool output omitted: #{omitted} chars omitted from #{char_count} chars, #{line_count} lines]

      #{t}
      """
      |> String.trim()
    end
  end

  defp compact_event_content(content), do: inspect(content)
end
