defmodule Beamcore.TUI.State do
  @moduledoc """
  Presentation-only state for the primary TUI.
  """

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Core.ToolDisplay
  alias Beamcore.Agent.Policy.ProjectPolicy

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
            unicode?: true,
            history: [],
            history_index: nil,
            history_draft: "",
            memory_total: nil

  def new(terminal, textarea, opts \\ []) do
    client = Keyword.get(opts, :client, Beamcore.OpenAI.client())
    history = Keyword.get(opts, :history, Beamcore.TUI.History.load())

    memory_total = compute_memory_total()

    %__MODULE__{
      terminal: terminal,
      textarea: textarea,
      session: Session.new(client),
      last_animation_tick_ms: System.monotonic_time(:millisecond),
      unicode?: Beamcore.TUI.Capability.unicode?(opts),
      history: history,
      history_index: nil,
      history_draft: "",
      memory_total: memory_total
    }
  end

  defp compute_memory_total() do
    {org, repo} = Beamcore.Memory.detect_org_repo()

    [:repo_map, :patterns, :decisions, :errors, :context]
    |> Enum.map(fn type -> length(Beamcore.Memory.list(org, repo, type)) end)
    |> Enum.sum()
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
      true -> clamp_poll(until_animation, 10, 16)
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

  # Intentionally unlimited backscroll to allow reading the full history.
  def scroll_up(state, amount \\ 1),
    do: %{state | scroll_offset: state.scroll_offset + amount} |> mark_dirty()

  def scroll_down(state, amount \\ 1),
    do: %{state | scroll_offset: max(state.scroll_offset - amount, 0)} |> mark_dirty()

  def reset_scroll(state), do: %{state | scroll_offset: 0} |> mark_dirty()

  defp auto_scroll_on_new_message(%{scroll_offset: offset} = state) when offset <= 2,
    do: reset_scroll(state)

  defp auto_scroll_on_new_message(state), do: state

  def pending_action(%{context: %{pending_action: action}}), do: action
  def pending_action(_session), do: nil

  def yolo?(%{policy_override: nil}), do: true
  def yolo?(%{policy_override: %{mode: :unrestricted}}), do: true
  def yolo?(_session), do: false

  def freedom?(%{project_policy_bypassed?: true}), do: true
  def freedom?(_session), do: false

  def usage(nil), do: %{last_prompt_tokens: 0, total_tokens: 0, needs_compaction: false}
  def usage(session), do: Session.usage(session)

  def model(_session), do: Beamcore.Agent.Chat.API.default_model()

  def provider do
    "mistral"
  end

  def policy_status(session \\ nil)

  def policy_status(%{project_policy_bypassed?: true}), do: "policy: bypassed"

  def policy_status(_session) do
    case ProjectPolicy.load() do
      %{loaded?: false} -> "policy: default"
      %{valid?: false} -> "policy: invalid"
      _policy -> "policy: loaded"
    end
  end

  def add_activity(state, name, args, status \\ :queued) do
    event = compact_activity(name, args, status)
    %{state | activity: Enum.take([event | state.activity], @max_activity)} |> mark_dirty()
  end

  def update_activity(state, name, args, result) do
    event = compact_activity(name, args, ToolDisplay.result_status(result), result)

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
    display = ToolDisplay.activity(name, args, status, result)

    %{
      id: System.unique_integer([:positive]),
      name: display.name,
      target: display.target,
      status: display.status,
      label: display.label,
      summary: display.summary,
      result: display.result
    }
  end

  def compact_text(value, limit \\ 180) do
    ToolDisplay.compact_text(value, limit)
  end
end
