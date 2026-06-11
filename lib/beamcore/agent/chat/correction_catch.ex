defmodule Beamcore.Agent.Chat.CorrectionCatch do
  @moduledoc """
  Detects and corrects braindead loops where the assistant is mechanically stuck —
  calling the same tool with the same arguments repeatedly, or oscillating between
  tools in a fixed pattern.

  Does NOT trigger on text patterns like "actually" or "let me try" — those are
  normal self-correction behavior and the model should have space to recover on its own.
  """

  alias Beamcore.Agent.Chat.{API, Session, Context}
  alias Beamcore.Agent.Core.StatusBar

  require Logger

  @max_corrections 3

  # ----- Public API -----

  @doc """
  Check if the assistant is stuck in a mechanical loop.

  Analyzes tool call patterns in recent messages. Returns `{true, reason}` if a
  loop is detected, or `false` if the model appears to be making progress.

  Detects two patterns:
  - **Exact repetition**: same tool + same args called ≥ 3 times in last 10 turns
  - **Oscillation**: alternating tool pattern repeating ≥ 3 full cycles in last 12 turns
  """
  def stuck?(messages) when is_list(messages) do
    fingerprints = extract_tool_fingerprints(messages)

    with false <- detect_repetition(fingerprints),
         false <- detect_oscillation(fingerprints) do
      false
    end
  end

  def stuck?(_), do: false

  @doc """
  Performs the correction by calling the LLM to diagnose the loop and formulate
  a structurally different approach. Then rolls over/compacts the session context.

  Skips correction if the session has already been corrected `@max_corrections` times.
  """
  def correct_and_rollover(session, messages, reason, pid) do
    if session.correction_count >= @max_corrections do
      if pid, do: StatusBar.update_text(pid, " ⚠️ Max corrections reached ")
      session
    else
      do_correct_and_rollover(session, messages, reason, pid)
    end
  end

  # ----- Detection -----

  @doc false
  def detect_repetition(fingerprints, window \\ 10) do
    recent = Enum.take(fingerprints, -window)

    case Enum.frequencies(recent) |> Enum.find(fn {_fp, count} -> count >= 3 end) do
      {{name, _args}, count} ->
        {true, "#{name} called #{count} times with identical arguments"}

      nil ->
        false
    end
  end

  @doc false
  def detect_oscillation(fingerprints, window \\ 12) do
    recent = Enum.take(fingerprints, -window)
    len = length(recent)

    # Try cycle lengths 2 and 3
    Enum.find_value([2, 3], false, fn cycle_len ->
      if len >= cycle_len * 3 do
        candidate = Enum.take(recent, -cycle_len * 3)

        # Extract names to check for oscillation
        candidate_names = Enum.map(candidate, fn {name, _args} -> name end)
        cycle_names = Enum.take(candidate_names, cycle_len)

        # A true oscillation must alternate between at least 2 different tools
        if length(Enum.uniq(cycle_names)) > 1 do
          full_reps = count_full_cycles(candidate_names, cycle_names)

          if full_reps >= 3 do
            # Format the cycle using the actual fingerprints of the first cycle rep
            formatted_cycle =
              candidate
              |> Enum.take(cycle_len)
              |> Enum.map(fn {name, args} -> format_tool_call_short(name, args) end)
              |> Enum.join(" → ")

            {true, "oscillating pattern: #{formatted_cycle} (repeated #{full_reps} times)"}
          end
        end
      end
    end) || false
  end

  # ----- Correction -----

  defp do_correct_and_rollover(session, messages, reason, pid) do
    if pid, do: StatusBar.update_text(pid, " ⚠️ Loop detected! Correcting... ")

    correction_prompt = %{
      role: "user",
      content: Beamcore.Agent.Core.Prompts.loop_diagnosis_request(reason)
    }

    trimmed = Session.trim_and_clean_messages(messages, 30)

    selection = Beamcore.Provider.Selection.primary(session.roles)
    model = selection.model || API.default_model()

    case API.execute(
           session.client,
           trimmed ++ [correction_prompt],
           [],
           :main,
           selection: selection,
           model: model,
           silent: true
         ) do
      {:ok, %{message: %{"content" => correction_content}}} ->
        build_corrected_session(session, messages, reason, correction_content, pid)

      {:error, reason_err} ->
        if pid, do: StatusBar.update_text(pid, " ⚠️ Correction failed: #{inspect(reason_err)} ")
        Session.summarize_and_rollover(session, messages, pid)
    end
  end

  defp build_corrected_session(session, messages, reason, correction_content, pid) do
    system_msg = List.first(session.messages)
    system_content = system_msg[:content] || system_msg["content"]

    combined_system = %{
      role: "system",
      content:
        Beamcore.Agent.Core.Prompts.loop_correction_system(
          system_content,
          reason,
          correction_content
        )
    }

    new_session = %{
      session
      | messages: [combined_system],
        last_prompt_tokens: 0,
        needs_compaction: false,
        compaction_count: session.compaction_count + 1,
        correction_count: session.correction_count + 1,
        total_prompt_tokens: 0,
        total_completion_tokens: 0,
        total_tokens: 0,
        context: Context.compact(session.context)
    }

    Session.log(new_session, %{
      event: "correction_compaction",
      reason: reason,
      correction_number: new_session.correction_count,
      compaction_number: new_session.compaction_count,
      previous_prompt_tokens: session.last_prompt_tokens,
      previous_total_tokens: session.total_tokens,
      messages_before: length(messages),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    if pid, do: StatusBar.update(pid, new_session)
    new_session
  end

  # ----- Fingerprinting -----

  @doc false
  def extract_tool_fingerprints(messages) when is_list(messages) do
    messages
    |> Enum.filter(&assistant_with_tool_calls?/1)
    |> Enum.flat_map(fn msg ->
      tool_calls = msg["tool_calls"] || msg[:tool_calls] || []

      Enum.map(tool_calls, fn tc ->
        name = tc["function"]["name"] || tc[:function][:name]
        raw_args = tc["function"]["arguments"] || tc[:function][:arguments] || %{}
        args = decode_and_normalize(raw_args)
        {name, args}
      end)
    end)
  end

  defp assistant_with_tool_calls?(msg) do
    role = msg[:role] || msg["role"]
    tool_calls = msg[:tool_calls] || msg["tool_calls"]
    role == "assistant" and is_list(tool_calls) and tool_calls != []
  end

  defp decode_and_normalize(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> normalize_args(decoded)
      _ -> %{}
    end
  end

  defp decode_and_normalize(args) when is_map(args), do: normalize_args(args)
  defp decode_and_normalize(_), do: %{}

  defp normalize_args(args) when is_map(args) do
    args
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_value(v)} end)
    |> Map.new()
  end

  defp normalize_value(v) when is_binary(v), do: String.trim(v)
  defp normalize_value(v) when is_map(v), do: normalize_args(v)
  defp normalize_value(v) when is_list(v), do: Enum.map(v, &normalize_value/1)
  defp normalize_value(v), do: v

  # ----- Oscillation helpers -----

  defp count_full_cycles(sequence, cycle) do
    cycle_len = length(cycle)
    seq_len = length(sequence)

    if cycle_len == 0 or seq_len < cycle_len do
      0
    else
      0..(div(seq_len, cycle_len) - 1)
      |> Enum.reduce_while(0, fn i, count ->
        chunk = Enum.slice(sequence, i * cycle_len, cycle_len)

        if chunk == cycle do
          {:cont, count + 1}
        else
          {:halt, count}
        end
      end)
    end
  end

  defp format_tool_call_short(name, args) when is_map(args) and args != %{} do
    # Get a compact key-value string of arguments
    keys_to_show = ["path", "filePath", "file", "command", "cmd"]

    shown_args =
      args
      |> Enum.filter(fn {k, _v} -> to_string(k) in keys_to_show end)
      |> Enum.map(fn {k, v} -> "#{k}: #{truncate_val(v)}" end)
      |> Enum.join(", ")

    if shown_args == "" do
      # Fallback to first few keys
      fallback_args =
        args
        |> Enum.take(2)
        |> Enum.map(fn {k, v} -> "#{k}: #{truncate_val(v)}" end)
        |> Enum.join(", ")

      if fallback_args == "" do
        name
      else
        "#{name}(#{fallback_args})"
      end
    else
      "#{name}(#{shown_args})"
    end
  end

  defp format_tool_call_short(name, _args), do: name

  defp truncate_val(val) when is_binary(val) do
    if String.length(val) > 20 do
      String.slice(val, 0, 17) <> "..."
    else
      val
    end
  end

  defp truncate_val(val), do: inspect(val)
end
