defmodule Beamcore.Agent.TUI.State do
  @moduledoc """
  Presentation-only state for the primary TUI.
  """

  alias Beamcore.Agent.Chat.Session

  @max_activity 80

  defstruct terminal: nil,
            textarea: nil,
            session: nil,
            messages: [],
            activity: [],
            selected_activity: 0,
            status: :idle,
            scroll_offset: 0,
            show_help: false,
            show_activity_details: false,
            show_commands: false,
            command_matches: [],
            command_selected: 0,
            spinner_step: 0,
            last_animation_tick_ms: 0,
            render_dirty?: true,
            worker: nil,
            unicode?: true

  def new(terminal, textarea, opts \\ []) do
    client = Keyword.get(opts, :client, Beamcore.Agent.OpenAI.client())

    %__MODULE__{
      terminal: terminal,
      textarea: textarea,
      session: Session.new(client),
      last_animation_tick_ms: System.monotonic_time(:millisecond),
      unicode?: Beamcore.Agent.TUI.Capability.unicode?(opts)
    }
  end

  def add_message(state, role, content) when is_binary(content) do
    content = String.trim(content)

    if content == "" do
      state
    else
      state
      |> Map.update!(:messages, &(&1 ++ [%{role: role, content: content}]))
      |> auto_scroll_on_new_message()
      |> mark_dirty()
    end
  end

  def set_status(state, status), do: %{state | status: status} |> mark_dirty()

  def set_session(state, session) do
    status = if pending_action(session), do: :waiting_for_confirmation, else: state.status
    %{state | session: session, status: status} |> mark_dirty()
  end

  def start_worker(state, pid), do: %{state | worker: pid, status: :thinking} |> mark_dirty()

  def finish_worker(state, session) do
    status = if pending_action(session), do: :waiting_for_confirmation, else: :idle
    %{set_session(state, session) | worker: nil, status: status} |> mark_dirty()
  end

  def mark_dirty(state), do: %{state | render_dirty?: true}
  def clear_dirty(state), do: %{state | render_dirty?: false}

  def tick(state, now_ms) do
    %{state | spinner_step: state.spinner_step + 1, last_animation_tick_ms: now_ms}
  end

  def animation_due?(%{last_animation_tick_ms: 0} = _state, now_ms) when now_ms < 0, do: true

  def animation_due?(state, now_ms) do
    now_ms - state.last_animation_tick_ms >= animation_interval(state)
  end

  def animation_interval(%{status: status, messages: messages}) do
    cond do
      status in [:thinking, :tool_running] -> 160
      status == :waiting_for_confirmation -> 280
      messages == [] -> 360
      true -> 420
    end
  end

  def poll_timeout_ms(state, now_ms) do
    elapsed = animation_elapsed_ms(state, now_ms)
    until_animation = max(animation_interval(state) - elapsed, 0)

    cond do
      state.status in [:thinking, :tool_running] -> clamp_poll(until_animation, 18, 42)
      state.show_commands -> 24
      state.worker != nil -> clamp_poll(until_animation, 24, 48)
      true -> clamp_poll(until_animation, 32, 64)
    end
  end

  defp animation_elapsed_ms(%{last_animation_tick_ms: 0}, now_ms) when now_ms < 0,
    do: animation_interval(%{status: :thinking, messages: []})

  defp animation_elapsed_ms(state, now_ms),
    do: max(now_ms - state.last_animation_tick_ms, 0)

  defp clamp_poll(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  def scroll_up(state, amount \\ 1),
    do: %{state | scroll_offset: min(state.scroll_offset + amount, 120)} |> mark_dirty()

  def scroll_down(state, amount \\ 1),
    do: %{state | scroll_offset: max(state.scroll_offset - amount, 0)} |> mark_dirty()

  def reset_scroll(state), do: %{state | scroll_offset: 0} |> mark_dirty()

  defp auto_scroll_on_new_message(%{scroll_offset: offset} = state) when offset <= 2,
    do: reset_scroll(state)

  defp auto_scroll_on_new_message(state), do: state

  def pending_action(%{context: %{pending_action: action}}), do: action
  def pending_action(_session), do: nil

  def yolo?(%{policy_override: %{mode: :unrestricted}}), do: true
  def yolo?(_session), do: false

  def usage(nil), do: %{last_prompt_tokens: 0, total_tokens: 0, needs_compaction: false}
  def usage(session), do: Session.usage(session)

  def model(_session), do: Beamcore.Agent.Chat.API.default_model()

  def provider do
    "mistral"
  end

  def add_activity(state, name, args, status \\ :queued) do
    event = compact_activity(name, args, status)
    %{state | activity: Enum.take([event | state.activity], @max_activity)} |> mark_dirty()
  end

  def update_activity(state, name, args, result) do
    event = compact_activity(name, args, result_status(result), result)

    activity =
      case state.activity do
        [%{name: ^name, target: target} = latest | rest] when target == event.target ->
          [Map.merge(latest, event) | rest]

        other ->
          [event | other]
      end

    %{state | activity: Enum.take(activity, @max_activity)} |> mark_dirty()
  end

  def compact_activity(name, args, status, result \\ nil) do
    name = to_string(name)
    target = target(name, args)

    %{
      id: System.unique_integer([:positive]),
      name: name,
      target: target,
      status: status,
      label: label(name, target, status),
      summary: summary(name, args, result),
      result: result_summary(result)
    }
  end

  defp target("image_generation", args), do: Map.get(args, "output_path")
  defp target("mix", args), do: compact_join([Map.get(args, "command"), Map.get(args, "args")])
  defp target("git", args), do: Map.get(args, "operation") || Map.get(args, "command")
  defp target("fs", args), do: compact_join([Map.get(args, "operation"), Map.get(args, "path")])

  defp target(_name, args),
    do: Map.get(args, "filePath") || Map.get(args, "path") || Map.get(args, "pattern")

  defp label(name, target, :blocked) when target in [nil, ""], do: "blocked #{name}"
  defp label(name, target, :blocked), do: "blocked #{name} #{target}"
  defp label(name, nil, _status), do: name
  defp label(name, "", _status), do: name
  defp label("image_generation", target, _status), do: "image_generation -> #{target}"
  defp label(name, target, _status), do: "#{name} #{target}"

  defp summary("image_generation", args, result) do
    prompt = compact_text(Map.get(args, "prompt", ""), 90)
    output = Map.get(args, "output_path")
    saved = saved_path(result)

    [prompt, output && "output #{output}", saved && "saved #{saved}", saved && "open #{saved}"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp summary("plan", args, _result) do
    files =
      ["create_files", "modify_files", "delete_files"]
      |> Enum.flat_map(&(Map.get(args, &1, []) || []))
      |> Enum.take(5)
      |> Enum.join(", ")

    compact_text((files == "" && Map.get(args, "summary", "pending plan")) || files)
  end

  defp summary("write", args, _result), do: byte_summary(args)
  defp summary("edit", args, _result), do: byte_summary(args)
  defp summary("patch", args, _result), do: patch_summary(Map.get(args, "patch_content", ""))
  defp summary(_name, _args, result), do: result_summary(result)

  defp byte_summary(args) do
    content = Map.get(args, "content") || Map.get(args, "new_string") || ""
    if content == "", do: "", else: "#{byte_size(content)} bytes"
  end

  defp patch_summary(patch) do
    "#{patch |> to_string() |> String.split("\n") |> length()} patch lines"
  end

  defp result_status("Error: Tool call blocked" <> _), do: :blocked
  defp result_status("Error: Mutation requires" <> _), do: :blocked
  defp result_status("Error: " <> _), do: :error
  defp result_status(_result), do: :done

  defp result_summary(nil), do: ""
  defp result_summary("Error: " <> reason), do: compact_text(reason)

  defp result_summary(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"summary" => summary}} ->
        compact_text(summary)

      {:ok, %{"ok" => true, "files" => files}} when is_list(files) ->
        compact_text(Enum.join(files, ", "))

      _ ->
        compact_text(result)
    end
  end

  defp result_summary(result), do: compact_text(inspect(result, limit: 4, printable_limit: 160))

  defp saved_path(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"files" => [file | _]}} -> file
      {:ok, %{"saved" => file}} -> file
      _ -> nil
    end
  end

  defp saved_path(_result), do: nil

  defp compact_join(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      value -> value
    end
  end

  def compact_text(value, limit \\ 180) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(limit)
  end

  defp truncate(text, limit) when byte_size(text) <= limit, do: text
  defp truncate(text, limit), do: String.slice(text, 0, max(limit - 3, 0)) <> "..."
end
