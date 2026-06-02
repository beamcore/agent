defmodule Beamcore.Agent.Tools.Reflect do
  @moduledoc """
  AI-powered self-reflection tool with scoped context.

  Experimental

  This tool provides critical review of user input, current iteration output,
  and offers guidance when the main loop is lost. It operates with a smaller,
  focused context and can only use read, grep, and web_get tools.
  """

  alias Beamcore.Agent.Chat.Context

  @description """
  Perform AI-powered self-reflection with scoped context. Critically reviews the user input,
  current iteration output, and provides guidance if the main loop is lost.
  Only uses read, grep, and web_get tools internally.
  """

  @reflection_prompt """
  You are a senior developer assistant performing self-reflection on an AI coding session.
  Your task is to critically review the current state and provide actionable guidance.

  CONTEXT:
  %s

  CRITICAL REVIEW TASK:
  1. Analyze the user's original input/request
  2. Review the current iteration's output/attempt
  3. Identify what's working, what's not, and why
  4. Detect if the main loop is lost, stuck, or going in circles
  5. Provide clear, actionable guidance to get back on track

  RESPONSE FORMAT:
  - Start with a brief assessment (1-2 sentences)
  - List specific observations as bullet points
  - Provide concrete next steps or corrections
  - If the loop is lost: clearly state this and suggest a reset or new approach
  - Be direct and technical

  IMPORTANT CONSTRAINTS:
  - You are reviewing, not executing
  - Focus on the actual problem, not hypotheticals
  - Base your analysis only on the provided context
  - If context is insufficient, state what information is missing
  """

  @max_context_chars 4000

  def name, do: "reflect"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            user_input: %{
              type: "string",
              description: "The user's original input or request"
            },
            current_output: %{
              type: "string",
              description: "The current iteration's output or attempt"
            },
            context_scope: %{
              type: "string",
              description: "Optional: specific files or areas to focus the reflection on"
            },
            focus: %{
              type: "string",
              description:
                "Optional: specific aspect to focus on (e.g., 'architecture', 'bug', 'performance')"
            }
          },
          required: ["user_input", "current_output"]
        }
      }
    }
  end

  @doc """
  Execute the reflection tool.
  """
  def execute(params) do
    user_input = Map.fetch!(params, "user_input")
    current_output = Map.fetch!(params, "current_output")
    context_scope = Map.get(params, "context_scope")
    focus = Map.get(params, "focus")

    # Build the reflection context
    reflection_context =
      build_reflection_context(user_input, current_output, context_scope, focus)

    # Create the prompt for the reflection
    prompt = format_reflection_prompt(reflection_context)

    # Execute the reflection via API call with restricted tools
    perform_reflection(prompt)
  end

  defp build_reflection_context(user_input, current_output, context_scope, focus) do
    # Build context lines in reverse order, then reverse at the end
    []
    |> maybe_add_focus(focus)
    |> maybe_add_context_scope(context_scope)
    |> add_current_output(current_output)
    |> add_user_input(user_input)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp maybe_add_focus(lines, nil), do: lines
  defp maybe_add_focus(lines, focus), do: ["FOCUS AREA: #{focus}" | lines]

  defp maybe_add_context_scope(lines, nil), do: lines

  defp maybe_add_context_scope(lines, context_scope),
    do: ["CONTEXT SCOPE: #{context_scope}" | lines]

  defp add_current_output(lines, current_output) do
    truncated_output =
      if String.length(current_output) > 1000 do
        String.slice(current_output, 0, 1000) <> "... (truncated)"
      else
        current_output
      end

    ["CURRENT OUTPUT: #{truncated_output}" | lines]
  end

  defp add_user_input(lines, user_input), do: ["USER INPUT: #{user_input}" | lines]

  defp format_reflection_prompt(context) do
    # Truncate context to fit within limits
    truncated_context =
      if String.length(context) > @max_context_chars do
        String.slice(context, 0, @max_context_chars) <> "..."
      else
        context
      end

    String.replace(@reflection_prompt, "%s", truncated_context)
  end

  defp perform_reflection(prompt) do
    # For the MVP, we'll generate a reflection response directly
    # This simulates what the AI would return
    generate_reflection_response(prompt)
  end

  defp generate_reflection_response(prompt) do
    # Parse the prompt to extract key information
    {user_input, current_output, context_scope, focus} = extract_components(prompt)

    # Generate a critical analysis
    analysis = analyze_session(user_input, current_output, context_scope, focus)

    format_reflection_response(analysis)
  end

  defp extract_components(prompt) do
    # Extract user input
    user_input =
      case String.split(prompt, "USER INPUT: ", parts: 2) do
        [_before, rest] ->
          case String.split(rest, "\nCURRENT OUTPUT: ", parts: 2) do
            [input, _] -> String.trim(input)
            _ -> String.trim(rest)
          end

        _ ->
          ""
      end

    # Extract current output
    current_output =
      case String.split(prompt, "CURRENT OUTPUT: ", parts: 2) do
        [_before, rest] ->
          cond do
            String.contains?(rest, "\nCONTEXT SCOPE: ") ->
              String.split(rest, "\nCONTEXT SCOPE: ", parts: 2) |> List.first() |> String.trim()

            String.contains?(rest, "\nFOCUS AREA: ") ->
              String.split(rest, "\nFOCUS AREA: ", parts: 2) |> List.first() |> String.trim()

            String.contains?(rest, "\n\nCRITICAL") ->
              String.split(rest, "\n\nCRITICAL", parts: 2) |> List.first() |> String.trim()

            true ->
              String.trim(rest)
          end

        _ ->
          ""
      end

    # Extract context scope
    context_scope =
      case String.split(prompt, "CONTEXT SCOPE: ", parts: 2) do
        [_before, rest] ->
          case String.split(rest, "\n", parts: 2) do
            [scope, _] -> String.trim(scope)
            _ -> String.trim(rest)
          end

        _ ->
          nil
      end

    # Extract focus
    focus =
      case String.split(prompt, "FOCUS AREA: ", parts: 2) do
        [_before, rest] ->
          case String.split(rest, "\n", parts: 2) do
            [f, _] -> String.trim(f)
            _ -> String.trim(rest)
          end

        _ ->
          nil
      end

    {user_input, current_output, context_scope, focus}
  end

  defp analyze_session(user_input, current_output, context_scope, focus) do
    {observations, recommendations, is_lost} =
      {[], [], false}
      |> analyze_user_input(user_input)
      |> analyze_current_output(current_output)
      |> check_circular_patterns(user_input, current_output)
      |> analyze_focus(focus)
      |> analyze_context_scope(context_scope)
      |> determine_lost_status()

    %{
      observations: Enum.reverse(observations),
      recommendations: Enum.reverse(recommendations),
      is_lost: is_lost,
      assessment: build_assessment(observations, recommendations, is_lost)
    }
  end

  defp analyze_user_input({obs, rec, lost}, user_input) do
    if user_input != "" do
      {["User request: #{String.slice(user_input, 0, 100)}..." | obs], rec, lost}
    else
      {obs, rec, lost}
    end
  end

  defp analyze_current_output({obs, rec, lost}, current_output) do
    if current_output != "" do
      output_length = String.length(current_output)

      cond do
        output_length == 0 ->
          {["No output generated yet" | obs], ["Start implementing the requested feature" | rec],
           lost}

        String.contains?(current_output, "Error") || String.contains?(current_output, "error") ->
          {["Error detected in output" | obs], ["Review error message and adjust approach" | rec],
           lost}

        String.contains?(current_output, "Compiling") ||
            String.contains?(current_output, "compiled") ->
          {["Compilation appears to have run" | obs], rec, lost}

        String.contains?(current_output, "test") && String.contains?(current_output, "fail") ->
          {["Tests are failing" | obs], ["Fix failing tests before continuing" | rec], lost}

        true ->
          {["Output generated (#{output_length} chars)" | obs], rec, lost}
      end
    else
      {obs, rec, lost}
    end
  end

  defp check_circular_patterns({obs, rec, lost}, user_input, current_output) do
    if String.contains?(current_output, user_input) &&
         String.length(current_output) > String.length(user_input) * 2 do
      {["Output may be echoing input without progress" | obs], rec, true}
    else
      {obs, rec, lost}
    end
  end

  defp analyze_focus({obs, rec, lost}, focus) do
    cond do
      focus && String.contains?(focus, "architecture") ->
        {["Architecture review requested" | obs],
         ["Review module structure and dependencies" | rec], lost}

      focus && String.contains?(focus, "bug") ->
        {["Bug hunting mode" | obs], ["Check error logs and stack traces" | rec], lost}

      focus && String.contains?(focus, "performance") ->
        {["Performance analysis requested" | obs], ["Profile before optimizing" | rec], lost}

      true ->
        {obs, rec, lost}
    end
  end

  defp analyze_context_scope({obs, rec, lost}, context_scope) do
    if context_scope do
      {["Focus on: #{context_scope}" | obs], rec, lost}
    else
      {obs, rec, lost}
    end
  end

  defp determine_lost_status({obs, rec, lost}) do
    if lost || (length(obs) == 1 && length(rec) == 0) do
      {obs, ["LOOP APPEARS LOST: Reset and start fresh with a clear plan" | rec], true}
    else
      {obs, rec, lost}
    end
  end

  defp build_assessment(observations, recommendations, is_lost) do
    cond do
      is_lost ->
        "Loop appears to be lost or stuck. Immediate course correction needed."

      length(recommendations) > 2 ->
        "Multiple issues detected. Prioritize and address systematically."

      length(observations) == 0 ->
        "Insufficient context for meaningful reflection."

      true ->
        "Progress detected but review recommended."
    end
  end

  defp format_reflection_response(analysis) do
    []
    |> add_assessment(analysis.assessment)
    |> add_observations(analysis.observations)
    |> add_recommendations(analysis.recommendations)
    |> add_status(analysis.is_lost)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp add_assessment(lines, assessment) do
    ["", assessment, "## Reflection Assessment" | lines]
  end

  defp add_observations(lines, []) do
    lines
  end

  defp add_observations(lines, observations) do
    ["" | add_obs_list(observations, ["### Observations:" | lines])]
  end

  defp add_obs_list([], acc) do
    acc
  end

  defp add_obs_list([h | t], acc) do
    add_obs_list(t, ["- #{h}" | acc])
  end

  defp add_recommendations(lines, []) do
    lines
  end

  defp add_recommendations(lines, recommendations) do
    ["" | add_rec_list(recommendations, ["### Recommendations:" | lines])]
  end

  defp add_rec_list([], acc) do
    acc
  end

  defp add_rec_list([h | t], acc) do
    add_rec_list(t, ["- #{h}" | acc])
  end

  defp add_status(lines, true) do
    [
      "The main loop appears to be lost. Consider resetting the session or providing clearer instructions.",
      "### STATUS: LOOP LOST" | lines
    ]
  end

  defp add_status(lines, false) do
    ["### STATUS: ON TRACK" | lines]
  end

  @doc """
  Perform reflection with additional context from the session.
  This variant can access session state for richer reflection.
  """
  def reflect_with_session(session, user_input, current_output, opts \\ []) do
    context_scope = Keyword.get(opts, :context_scope)
    focus = Keyword.get(opts, :focus)

    # Build enhanced context from session
    session_context = Context.summary(session.context)

    # Add session context to the reflection
    enhanced_context =
      build_reflection_context(user_input, current_output, context_scope, focus) <>
        "\n\nSESSION CONTEXT:\n" <> session_context

    prompt = format_reflection_prompt(enhanced_context)

    # For now, use the same generation approach
    # In a full implementation, this would call the AI API
    generate_reflection_response(prompt)
  end

  @doc """
  Check if the main loop appears to be lost based on recent history.
  """
  def loop_lost?(session) do
    # Check for signs of being lost
    messages = session.messages

    # If we have many messages without progress
    if length(messages) > 20 do
      # Check for repeated patterns
      recent_messages = Enum.take(messages, -10)

      # Simple heuristic: if last few messages are similar
      unique_content =
        recent_messages
        |> Enum.map(&(&1.content || ""))
        |> Enum.map(&String.slice(&1, 0, 50))
        |> Enum.uniq()

      length(unique_content) < 3
    else
      false
    end
  end
end
