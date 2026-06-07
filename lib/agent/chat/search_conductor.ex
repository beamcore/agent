defmodule Beamcore.Agent.Chat.SearchConductor do
  @moduledoc """
  Optional pre-flight workspace search conductor.

  It runs only when the user explicitly enables a helper provider/model. The
  helper is provider-neutral and may be any configured model with suitable
  chat/tool capabilities.
  """

  alias Beamcore.Agent.Chat.Context
  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Core.Pretty
  alias Beamcore.Agent.Tools.Dispatcher

  require Logger

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
  Performs pre-flight workspace search only when a helper role is enabled.
  Returns the updated session with search messages and updated context.
  """
  def preflight(session, messages, content, policy, opts \\ []) do
    # The helper is opt-in. The environment switch can additionally disable it.
    if System.get_env("BEAMCORE_SEARCH_CONDUCTOR") == "false" do
      {messages, session}
    else
      case helper_selection(session) do
        {:ok, selection} ->
          run_preflight(session, messages, content, selection, policy, opts)

        _ ->
          # Silently fallback to main reasoning flow
          {messages, session}
      end
    end
  end

  defp run_preflight(session, messages, content, selection, policy, opts) do
    helper_policy = ToolPolicy.local_context_helper(policy)
    tools = search_tool_specs(helper_policy)

    if Enum.empty?(tools) do
      {messages, session}
    else
      preflight_prompt_messages = [
        %{role: "system", content: @system_prompt},
        %{role: "user", content: content}
      ]

      # Indicate to TUI and console that local search is starting
      emit(opts, {:status, :local_search})

      emit(
        opts,
        {:local_info, "Checking workspace search needs via helper model (#{selection.model})..."}
      )

      maybe_print(opts, fn ->
        IO.puts(
          IO.ANSI.cyan() <>
            "* Helper (#{selection.provider}/#{selection.model}) -> checking workspace search needs..." <>
            IO.ANSI.reset()
        )
      end)

      res =
        Beamcore.Provider.Router.chat(selection, %{
          model: selection.model,
          messages: preflight_prompt_messages,
          tools: tools
        })

      case res do
        {:ok, %{"choices" => [%{"message" => assistant_message} | _]}} ->
          if has_tool_calls?(assistant_message) do
            emit(opts, {:local_info, "Local search tools detected. Running local pre-flight..."})
            execute_preflight_tools(session, messages, assistant_message, helper_policy, opts)
          else
            emit(opts, {:local_info, "No search tools needed."})
            emit(opts, {:status, :thinking})
            {messages, session}
          end

        error ->
          # Helper failure must never pollute or stop the primary chat flow.
          emit(opts, {:status, :thinking})
          Logger.debug("Optional helper pre-flight failed: #{safe_error(error)}")
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
      IO.puts(IO.ANSI.cyan() <> "* Helper -> pre-flight search completed." <> IO.ANSI.reset())
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

  defp helper_selection(%{roles: roles}) do
    case Beamcore.Provider.Selection.helper(roles) do
      %{enabled: true, provider: provider, model: model} = selection
      when is_binary(provider) and is_binary(model) ->
        validate_helper_selection(selection)

      _ ->
        {:error, :disabled}
    end
  end

  defp helper_selection(_session), do: {:error, :disabled}

  defp validate_helper_selection(selection) do
    with {:ok, provider} <- Beamcore.Provider.Registry.validate_selection(selection.provider),
         true <- provider.capabilities.chat do
      validate_discovered_model(provider, selection)
    else
      _ -> {:error, :unavailable}
    end
  end

  # Discovery validates the exact model selected by the user. It never silently
  # replaces that model with Gemma, FunctionGemma, or another guessed default.
  defp validate_discovered_model(
         %{name: provider, discovery: discovery},
         %{model: model} = selection
       )
       when is_atom(discovery) and not is_nil(discovery) do
    if Beamcore.Provider.Health.model_available?(provider, model),
      do: {:ok, selection},
      else: {:error, :unavailable}
  end

  defp validate_discovered_model(_provider, selection), do: {:ok, selection}

  defp safe_error({:error, %{message: message}}) when is_binary(message), do: message
  defp safe_error({:error, reason}), do: inspect(reason, limit: 8, printable_limit: 240)
  defp safe_error(reason), do: inspect(reason, limit: 8, printable_limit: 240)
end
