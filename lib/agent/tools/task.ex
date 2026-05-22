defmodule Beamcore.Agent.Tools.Task do
  @moduledoc """
  Tool to execute a task as an agent without a chat session.
  """

  alias Beamcore.Agent.Chat.API
  alias Beamcore.Agent.Tools.Dispatcher
  alias Beamcore.Agent.OpenAI

  @description """
  Execute a sub-task using an autonomous agent separate from the active chat session.
  Uses a prompt instruction and handles complex or multi-step background operations.
  Returns a summarized result of the agent's work and tools executed.
  """

  @funny_names [
    "dusty_cat",
    "sneezing_walrus",
    "grumpy_otter",
    "wobbly_penguin",
    "lazy_sloth",
    "chatty_parrot",
    "bouncy_kangaroo",
    "sleepy_koala",
    "clumsy_panda",
    "zany_lemur",
    "jolly_narwhal",
    "quirky_quokka",
    "goofy_giraffe",
    "peppy_platypus",
    "mellow_manatee"
  ]

  def name, do: "task"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "The unique name of the sub-agent."
            },
            prompt: %{
              type: "string",
              description: "The task prompt or instruction for the agent to execute."
            },
            model: %{
              type: "string",
              description: "The model to use for the task. Defaults to 'mistral-medium-3.5'."
            }
          },
          required: ["prompt", "name"]
        }
      }
    }
  end

  def execute(params) do
    prompt = Map.fetch!(params, "prompt")

    name =
      params
      |> Map.get("name", "unknown")
      |> ensure_funny_name()

    messages = [
      %{
        role: "system",
        content: """
        You are an autonomous sub-agent, a tiny agent that follows the conductor.
        Your name is #{name}.
        Follow the instructions provided in the conductor's prompt precisely.
        Use the available tools to assist in completing the task.
        Return the final result or output of the task.
        """
      },
      %{
        role: "user",
        content: prompt
      }
    ]

    initial_state = %{
      consecutive_errors: 0,
      tool_call_history: [],
      trimmed_on_bad_request: false
    }

    process_subagent(messages, 0, name, initial_state)
  end

  defp process_subagent(_messages, depth, _name, _state) when depth >= 25 do
    "Error: Sub-agent reached tool depth limit of 25."
  end

  defp process_subagent(_messages, _depth, name, %{consecutive_errors: errors})
       when errors >= 3 do
    "Error: Sub-agent #{name} hit #{errors} consecutive API errors. Aborting to prevent loop."
  end

  defp process_subagent(messages, depth, name, state) do
    client = OpenAI.client()
    tools = Dispatcher.tool_specs()

    trimmed = trim_messages(messages)

    case API.execute(client, trimmed, tools, {:subagent, name}) do
      {:ok, %{message: message, raw_response: _raw_response}} ->
        new_messages = messages ++ [message]

        if message["tool_calls"] && message["tool_calls"] != [] do
          # Build a fingerprint of this tool call set for loop detection
          call_fingerprint =
            message["tool_calls"]
            |> Enum.map(fn tc ->
              {tc["function"]["name"], tc["function"]["arguments"]}
            end)
            |> :erlang.phash2()

          updated_history = state.tool_call_history ++ [call_fingerprint]

          if stuck_in_loop?(updated_history) do
            "Error: Sub-agent #{name} is stuck in a loop — repeating the same tool calls. Aborting."
          else
            tool_responses =
              Enum.map(message["tool_calls"], fn tool_call ->
                name = tool_call["function"]["name"]
                args_str = tool_call["function"]["arguments"]

                args =
                  case Jason.decode(args_str) do
                    {:ok, decoded} -> decoded
                    _ -> %{}
                  end

                content = Dispatcher.execute(name, args)

                %{
                  role: "tool",
                  tool_call_id: tool_call["id"],
                  name: name,
                  content: content
                }
              end)

            new_state = %{state | consecutive_errors: 0, tool_call_history: updated_history}
            process_subagent(new_messages ++ tool_responses, depth + 1, name, new_state)
          end
        else
          message["content"] || "Sub-agent completed but produced no text response."
        end

      {:error, %OpenaiEx.Error{kind: :bad_request}} ->
        # Likely context overflow — try aggressive trimming once
        if not state.trimmed_on_bad_request do
          aggressively_trimmed = aggressive_trim_messages(messages)

          new_state = %{
            state
            | trimmed_on_bad_request: true,
              consecutive_errors: state.consecutive_errors + 1
          }

          process_subagent(aggressively_trimmed, depth, name, new_state)
        else
          "Error: Sub-agent #{name} received bad_request after trimming. Cannot recover."
        end

      {:error, %OpenaiEx.Error{kind: :rate_limit}} ->
        "Error: Rate limit exceeded. Please try again later."

      {:error, %OpenaiEx.Error{kind: :api_timeout_error}} ->
        "Error: API timeout. Please try again."

      {:error, %OpenaiEx.Error{} = error} ->
        # Extract detailed error information for debugging
        error_details =
          if error.message do
            "message: #{error.message}"
          else
            "status_code: #{error.status_code || ~c"unknown"}"
          end

        error_body =
          if error.body do
            " | body: #{inspect(error.body)}"
          else
            ""
          end

        new_state = %{state | consecutive_errors: state.consecutive_errors + 1}

        if new_state.consecutive_errors >= 3 do
          "Error: Sub-agent #{name} hit #{new_state.consecutive_errors} consecutive API errors. Last: #{error.kind} (#{error_details}#{error_body})"
        else
          process_subagent(messages, depth, name, new_state)
        end

      {:error, reason} ->
        "Error: #{inspect(reason)}"
    end
  end

  @doc false
  # Detects if the last N fingerprints contain a repeating cycle.
  # Catches patterns like A-B-A-B (flip-flop) or A-A-A (same call repeated).
  defp stuck_in_loop?(history) when length(history) < 4, do: false

  defp stuck_in_loop?(history) do
    recent = Enum.take(history, -6)

    # Check for direct repetition: same fingerprint 3+ times in last 6
    recent
    |> Enum.frequencies()
    |> Enum.any?(fn {_fp, count} -> count >= 3 end)
  end

  @doc false
  # More aggressive trimming — keep system + last 20 messages
  defp aggressive_trim_messages(messages) do
    {system, rest} =
      Enum.split_with(messages, fn m ->
        (m[:role] || m["role"]) == "system"
      end)

    system ++ Enum.take(rest, -20)
  end

  defp trim_messages(messages) do
    if length(messages) <= 40 do
      messages
    else
      {system, rest} =
        Enum.split_with(messages, fn m ->
          (m[:role] || m["role"]) == "system"
        end)

      system ++ Enum.take(rest, -(40 - length(system)))
    end
  end

  def ensure_funny_name(name) do
    if name in @funny_names do
      name
    else
      Enum.random(@funny_names)
    end
  end
end
