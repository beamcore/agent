defmodule Beamcore.Agent.SubAgent do
  @moduledoc "Simple interface for spawning sub-agents to offload work to cheaper/faster models."

  alias Beamcore.Agent.Chat.API

  @default_timeout 60_000
  @max_tool_depth 15

  @doc "Run a sub-agent task synchronously."
  def run(task, opts \\ []) when is_binary(task) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case run_async(task, opts) |> Task.await(timeout) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Run a sub-agent task asynchronously."
  def run_async(task, opts \\ []) when is_binary(task) do
    Task.async(fn -> execute(task, opts) end)
  end

  @doc "Same as run/2 but raises on error."
  def run!(task, opts \\ []) do
    case run(task, opts) do
      {:ok, response} -> response
      {:error, _reason} -> raise "SubAgent failed"
    end
  end

  defp execute(task, opts) do
    selection = build_selection(opts)
    temperature = Keyword.get(opts, :temperature, 0.7)
    tools_requested = Keyword.get(opts, :tools, true)
    system_prompt = Keyword.get(opts, :system, default_system_prompt())

    caps = Beamcore.Agent.Chat.ToolRuntime.default()
    tools = if tools_requested, do: get_tools(caps, tools_requested), else: []

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: task}
    ]

    agent_loop(selection, messages, tools, temperature, 0)
  end

  defp agent_loop(selection, messages, tools, temperature, depth) do
    if depth > @max_tool_depth do
      {:error, :max_depth_exceeded}
    else
      case API.execute(nil, messages, tools,
             selection: selection,
             temperature: temperature
           ) do
        {:ok, %{message: message}} ->
          handle_response(message, selection, messages, tools, temperature, depth)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_response(
         %{"tool_calls" => [_ | _] = tool_calls},
         selection,
         messages,
         tools,
         temperature,
         depth
       ) do
    tool_results = execute_tool_calls(tool_calls)
    new_messages = messages ++ [message_from_calls(tool_calls)] ++ tool_results
    agent_loop(selection, new_messages, tools, temperature, depth + 1)
  end

  defp handle_response(%{"content" => content}, _sel, _msgs, _tools, _temp, _depth)
       when is_binary(content), do: {:ok, content}

  defp handle_response(_message, _sel, _msgs, _tools, _temp, _depth),
    do: {:error, :unexpected_response}

  defp message_from_calls(tool_calls),
    do: %{role: "assistant", content: nil, tool_calls: tool_calls}

  defp execute_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn call ->
      args = Jason.decode!(call["function"]["arguments"])
      result = Beamcore.Agent.Tools.Eeva.execute(args)
      %{role: "tool", tool_call_id: call["id"], content: result}
    end)
  end

  defp build_selection(opts) do
    provider = Keyword.get(opts, :provider) || Beamcore.Config.active_provider()
    model = Keyword.get(opts, :model) || provider_default_model(provider)
    %{provider: provider, model: model, enabled: true}
  end

  defp provider_default_model(provider) do
    case Beamcore.Config.get_provider(provider) do
      %{"default_model" => model} when is_binary(model) -> model
      _ -> Beamcore.Agent.Chat.API.default_model()
    end
  end

  defp get_tools(caps, true), do: Beamcore.Agent.Tools.Dispatcher.tool_specs(caps)

  defp get_tools(caps, tool_names) when is_list(tool_names) do
    all = Beamcore.Agent.Tools.Dispatcher.tool_specs(caps)
    Enum.filter(all, &(&1["function"]["name"] in tool_names))
  end

  defp default_system_prompt do
    "You are a sub-agent. Complete the task concisely and return the result. Be direct and efficient. When using tools, make minimal calls and return findings immediately."
  end
end
