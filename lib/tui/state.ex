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
            activity_scroll_offset: 0,
            details_scroll_offset: 0,
            show_help: false,
            show_activity_details: false,
            show_commands: false,
            command_matches: [],
            command_selected: 0,
            spinner_step: 0,
            last_animation_tick_ms: 0,
            render_dirty?: true,
            worker: nil,
            pending_login?: false,
            unicode?: true,
            history: [],
            history_index: nil,
            history_draft: "",
            memory_total: nil,
            file_finder_active?: false,
            file_finder_query: "",
            file_finder_results: [],
            file_finder_selected: 0,
            file_finder_cache: nil,
            provider_selector_active?: false,
            provider_selector_results: [],
            provider_selector_selected: 0,
            pending_provider_key?: false,
            pending_provider_name: nil,
            notice: nil

  def new(terminal, textarea, opts \\ []) do
    client = client(opts)
    history = Keyword.get(opts, :history, Beamcore.TUI.History.load())

    memory_total = compute_memory_total()

    messages =
      if client,
        do: [],
        else: [
          %{
            role: :system,
            content:
              "Beamcore is not configured for the selected primary provider. Use Ctrl+O or /api select to choose/configure one."
          }
        ]

    %__MODULE__{
      terminal: terminal,
      textarea: textarea,
      session: Session.new(client, opts),
      messages: messages,
      last_animation_tick_ms: System.monotonic_time(:millisecond),
      unicode?: Beamcore.TUI.Capability.unicode?(opts),
      history: history,
      history_index: nil,
      history_draft: "",
      memory_total: memory_total
    }
  end

  defp client(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, client} -> client
      :error -> nil
    end
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

  def set_notice(state, content) when is_binary(content) do
    content = Beamcore.TUI.ErrorFormatter.format(content)
    %{state | notice: if(content == "", do: nil, else: content)} |> mark_dirty()
  end

  def clear_notice(state), do: %{state | notice: nil} |> mark_dirty()

  def paused?(%{status: :paused}), do: true
  def paused?(_state), do: false

  def pause(state), do: %{state | status: :paused} |> mark_dirty()

  def resume(state), do: %{state | status: :idle} |> mark_dirty()

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
      status in [:thinking, :tool_running, :local_search] -> 160
      status == :waiting_for_confirmation -> 280
      messages == [] -> 360
      true -> 420
    end
  end

  def poll_timeout_ms(state, now_ms) do
    elapsed = animation_elapsed_ms(state, now_ms)
    until_animation = max(animation_interval(state) - elapsed, 0)

    cond do
      state.status in [:thinking, :tool_running, :local_search] ->
        clamp_poll(until_animation, 18, 42)

      state.show_commands ->
        24

      state.worker != nil ->
        clamp_poll(until_animation, 24, 48)

      true ->
        clamp_poll(until_animation, 10, 16)
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

  def scroll_activity_up(state, amount \\ 1),
    do: %{state | activity_scroll_offset: state.activity_scroll_offset + amount} |> mark_dirty()

  def scroll_activity_down(state, amount \\ 1),
    do:
      %{state | activity_scroll_offset: max(state.activity_scroll_offset - amount, 0)}
      |> mark_dirty()

  def reset_activity_scroll(state), do: %{state | activity_scroll_offset: 0} |> mark_dirty()

  def scroll_details_up(state, amount \\ 1),
    do:
      %{state | details_scroll_offset: max(state.details_scroll_offset - amount, 0)}
      |> mark_dirty()

  def scroll_details_down(state, amount \\ 1),
    do: %{state | details_scroll_offset: state.details_scroll_offset + amount} |> mark_dirty()

  def reset_details_scroll(state), do: %{state | details_scroll_offset: 0} |> mark_dirty()

  defp auto_scroll_on_new_activity(%{activity_scroll_offset: offset} = state) when offset <= 2,
    do: reset_activity_scroll(state)

  defp auto_scroll_on_new_activity(state), do: state

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
    Beamcore.Config.active_provider()
  end

  def helper_label(%{roles: roles}) do
    case Beamcore.Provider.Selection.helper(roles) do
      %{enabled: true, provider: provider, model: model} -> "#{provider}/#{model}"
      _ -> "helper"
    end
  end

  def helper_label(_session), do: "helper"

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

    %{state | activity: Enum.take([event | state.activity], @max_activity)}
    |> auto_scroll_on_new_activity()
    |> mark_dirty()
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

    %{state | activity: Enum.take(activity, @max_activity)}
    |> auto_scroll_on_new_activity()
    |> mark_dirty()
  end

  def compact_activity(name, args, status, result \\ nil) do
    display = ToolDisplay.activity(name, args, status, result)

    %{
      id: System.unique_integer([:positive]),
      timestamp_ms: System.system_time(:millisecond),
      name: display.name,
      target: display.target,
      status: display.status,
      label: display.label,
      summary: display.summary,
      result: compact_activity_result(result),
      args: compact_args(args)
    }
  end

  def compact_args(args) when is_map(args) do
    args
    |> Enum.map(fn {key, val} ->
      val_compact =
        cond do
          is_binary(val) ->
            if String.length(val) > 60 do
              String.slice(val, 0, 57) <> "..."
            else
              val
            end

          is_map(val) ->
            compact_args(val)

          is_list(val) ->
            Enum.map(val, fn
              item when is_map(item) ->
                compact_args(item)

              item when is_binary(item) ->
                if String.length(item) > 60, do: String.slice(item, 0, 57) <> "...", else: item

              item ->
                item
            end)

          true ->
            val
        end

      {key, val_compact}
    end)
    |> Map.new()
  end

  def compact_args(args), do: args

  defp compact_activity_result(nil), do: nil

  defp compact_activity_result(result) when is_binary(result) do
    ToolDisplay.compact_text(result, 1_200)
  end

  defp compact_activity_result(result) do
    result
    |> inspect(pretty: false, limit: 16, printable_limit: 1_000)
    |> ToolDisplay.compact_text(1_200)
  end

  def compact_text(value, limit \\ 180) do
    ToolDisplay.compact_text(value, limit)
  end

  # File finder state management
  def activate_file_finder(state, query, results) do
    %{
      state
      | file_finder_active?: true,
        file_finder_query: query,
        file_finder_results: results,
        file_finder_selected: 0
    }
    |> mark_dirty()
  end

  def deactivate_file_finder(state) do
    %{
      state
      | file_finder_active?: false,
        file_finder_query: "",
        file_finder_results: [],
        file_finder_selected: 0
    }
    |> mark_dirty()
  end

  def update_file_finder_query(state, query, results) do
    %{
      state
      | file_finder_query: query,
        file_finder_results: results,
        file_finder_selected: min(state.file_finder_selected, max(length(results) - 1, 0))
    }
    |> mark_dirty()
  end

  def select_file_finder_result(state, offset) do
    max_index = max(length(state.file_finder_results) - 1, 0)
    selected = state.file_finder_selected + offset
    %{state | file_finder_selected: selected |> max(0) |> min(max_index)} |> mark_dirty()
  end

  # Provider selector state management
  def load_providers_list do
    Beamcore.Provider.Registry.list()
  end

  def format_provider_item(%{} = provider) do
    helper = Beamcore.Config.helper_selection()

    roles =
      [
        provider.active? && "primary",
        is_map(helper) && helper.provider == provider.name && "helper:#{helper.model}"
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(",")
      |> case do
        "" -> ""
        value -> " [#{value}]"
      end

    prefix = if provider.active?, do: "* ", else: "  "
    state = if provider.configured?, do: "configured", else: "not configured"
    scope = if provider.capabilities.local, do: "local", else: "remote"
    tools = if provider.capabilities.tool_calls, do: "tools", else: "text"
    model = provider.default_model || "choose model"
    base_url = provider.base_url || "custom endpoint"

    "#{prefix}#{provider.name}#{roles} #{state} · #{scope} · #{tools} · #{model} · #{base_url}"
  end

  def activate_provider_selector(state) do
    results = load_providers_list()
    # Find the index of the active provider to highlight it initially
    active_idx = Enum.find_index(results, fn provider -> provider.active? end) || 0

    %{
      state
      | provider_selector_active?: true,
        provider_selector_results: results,
        provider_selector_selected: active_idx
    }
    |> mark_dirty()
  end

  def deactivate_provider_selector(state) do
    %{
      state
      | provider_selector_active?: false,
        provider_selector_results: [],
        provider_selector_selected: 0
    }
    |> mark_dirty()
  end

  def select_provider_selector_result(state, offset) do
    max_index = max(length(state.provider_selector_results) - 1, 0)
    selected = state.provider_selector_selected + offset
    %{state | provider_selector_selected: selected |> max(0) |> min(max_index)} |> mark_dirty()
  end
end
