defmodule Beamcore.TUI.State do
  @moduledoc """
  Presentation-only state for the primary TUI.
  """

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Core.ToolDisplay
  alias Beamcore.Agent.Policy.ProjectPolicy

  @max_activity 500

  defstruct terminal: nil,
            textarea: nil,
            session: nil,
            messages: [],
            activity: [],
            selected_activity: 0,
            selected_event_id: nil,
            activity_focused?: false,
            activity_follow_tail?: true,
            activity_unseen_count: 0,
            activity_viewport_height: 0,
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
            selected_checkpoint_id: nil,
            notice: nil,
            screen_type: :agent

  def new(terminal, textarea, opts \\ []) do
    client = client(opts)
    history = Keyword.get(opts, :history, Beamcore.TUI.History.load())

    memory_total = compute_memory_total()
    screen_type = Keyword.get(opts, :screen_type, :agent)

    provider_ready? = primary_provider_ready?(screen_type)

    messages =
      if client || provider_ready?,
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
      memory_total: memory_total,
      screen_type: screen_type
    }
  end

  defp client(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, client} -> client
      :error -> nil
    end
  end

  defp primary_provider_ready?(screen_type) do
    settings = Beamcore.Agent.Chat.ModeSettings.resolve(screen_type)

    case Beamcore.Provider.Registry.validate_selection(settings.provider) do
      {:ok, _provider} -> true
      _ -> false
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

  def refresh_memory_total(state) do
    %{state | memory_total: compute_memory_total()} |> mark_dirty()
  rescue
    _error -> state
  catch
    _, _ -> state
  end

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
    selected_checkpoint_id = state.selected_checkpoint_id || active_checkpoint_id(session)
    state = update_activity_live_follow(state, session)

    %{state | session: session, selected_checkpoint_id: selected_checkpoint_id}
    |> mark_dirty()
  end

  def start_worker(state, pid), do: %{state | worker: pid, status: :thinking} |> mark_dirty()

  def finish_worker(state, session) do
    %{set_session(state, session) | worker: nil, status: :idle} |> mark_dirty()
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
    do:
      state
      |> Map.put(:activity_follow_tail?, false)
      |> Map.update!(:activity_scroll_offset, &(&1 + amount))
      |> Map.put(:activity_focused?, true)
      |> mark_dirty()

  def scroll_activity_down(state, amount \\ 1),
    do:
      state
      |> Map.update!(:activity_scroll_offset, &max(&1 - amount, 0))
      |> maybe_resume_activity_follow()
      |> Map.put(:activity_focused?, true)
      |> mark_dirty()

  def reset_activity_scroll(state),
    do:
      state
      |> follow_activity_tail()
      |> Map.put(:activity_focused?, true)
      |> mark_dirty()

  defp follow_activity_tail(state),
    do:
      %{
        state
        | activity_scroll_offset: 0,
          activity_follow_tail?: true,
          activity_unseen_count: 0,
          selected_activity: max(length(timeline_items(state)) - 1, 0)
      }
      |> put_selected_event_id()

  def scroll_details_up(state, amount \\ 1),
    do:
      %{state | details_scroll_offset: max(state.details_scroll_offset - amount, 0)}
      |> mark_dirty()

  def scroll_details_down(state, amount \\ 1),
    do: %{state | details_scroll_offset: state.details_scroll_offset + amount} |> mark_dirty()

  def reset_details_scroll(state), do: %{state | details_scroll_offset: 0} |> mark_dirty()

  defp auto_scroll_on_new_activity(%{activity_scroll_offset: offset} = state) when offset <= 2,
    do: follow_activity_tail(state)

  defp auto_scroll_on_new_activity(state), do: state

  def focus_activity(state) do
    state
    |> Map.put(:activity_focused?, true)
    |> put_selected_event_id()
    |> mark_dirty()
  end

  def blur_activity(state), do: %{state | activity_focused?: false} |> mark_dirty()

  def move_activity_selection(state, offset) do
    items = timeline_items(state)
    max_index = max(length(items) - 1, 0)
    selected = clamp(state.selected_activity + offset, 0, max_index)

    %{
      state
      | selected_activity: selected,
        activity_focused?: true,
        activity_follow_tail?: selected == max_index,
        activity_unseen_count: if(selected == max_index, do: 0, else: state.activity_unseen_count)
    }
    |> ensure_selected_visible()
    |> put_selected_event_id()
    |> mark_dirty()
  end

  def activity_page(state, direction) do
    amount = max(state.activity_viewport_height - 2, 1)
    move_activity_selection(state, if(direction == :up, do: -amount, else: amount))
  end

  def activity_home(state) do
    %{
      state
      | selected_activity: 0,
        activity_scroll_offset: max(length(timeline_items(state)) - 1, 0),
        activity_follow_tail?: false,
        activity_focused?: true
    }
    |> put_selected_event_id()
    |> mark_dirty()
  end

  def activity_end(state), do: reset_activity_scroll(state)

  def set_activity_viewport_height(state, height) do
    height = max(height, 0)

    %{state | activity_viewport_height: height}
    |> clamp_activity_selection()
    |> ensure_selected_visible()
    |> mark_dirty()
  end

  def visible_timeline_items(state, viewport_height, overscan \\ 2) do
    source = timeline_source(state)
    count = length(source)
    height = max(viewport_height, 1)

    start =
      cond do
        count == 0 -> 0
        state.activity_follow_tail? -> max(count - height - overscan, 0)
        true -> max(state.selected_activity - div(height, 2) - overscan, 0)
      end

    stop = min(start + height + overscan * 2, count)

    source
    |> Enum.slice(start, stop - start)
    |> Enum.map(&timeline_source_to_activity(&1, state))
  end

  def activity_indicator(%{activity_follow_tail?: true}), do: ""

  def activity_indicator(%{activity_unseen_count: count}) when count > 0,
    do: "Paused · #{count} new events"

  def activity_indicator(%{activity_follow_tail?: false}), do: "Paused"

  def yolo?(%{policy_override: nil}), do: true
  def yolo?(%{policy_override: %{mode: :unrestricted}}), do: true
  def yolo?(_session), do: false

  def freedom?(%{project_policy_bypassed?: true}), do: true
  def freedom?(_session), do: false

  def usage(nil), do: %{last_prompt_tokens: 0, total_tokens: 0, needs_compaction: false}
  def usage(session), do: Session.usage(session)

  def model(session) do
    case session.roles do
      %{primary: %{model: model}} -> model
      _ -> Beamcore.Agent.Chat.API.default_model()
    end
  end

  def provider(session) do
    case session.roles do
      %{primary: %{provider: provider}} -> provider
      _ -> Beamcore.Config.active_provider()
    end
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

  def timeline_items(%{session: %{timeline: timeline}} = state)
      when is_list(timeline) and length(timeline) > 1 do
    timeline
    |> Enum.reject(&(&1.type == :checkpoint_saved))
    |> Enum.map(&timeline_event_to_activity(&1, state.session))
  end

  def timeline_items(state), do: state.activity

  defp timeline_source(%{session: %{timeline: timeline}})
       when is_list(timeline) and length(timeline) > 1 do
    Enum.reject(timeline, &(&1.type == :checkpoint_saved))
  end

  defp timeline_source(state), do: state.activity

  defp timeline_source_to_activity(%{type: type} = event, state) when is_atom(type),
    do: timeline_event_to_activity(event, state.session)

  defp timeline_source_to_activity(item, _state), do: item

  def active_checkpoint_id(%{active_checkpoint_id: checkpoint_id}), do: checkpoint_id
  def active_checkpoint_id(_session), do: nil

  def select_checkpoint(state, checkpoint_id) when is_binary(checkpoint_id) do
    %{state | selected_checkpoint_id: checkpoint_id} |> mark_dirty()
  end

  def selected_checkpoint(state) do
    checkpoint_id = state.selected_checkpoint_id || active_checkpoint_id(state.session)

    Enum.find(state.session.checkpoints || [], fn checkpoint ->
      checkpoint.id == checkpoint_id
    end)
  end

  def branch_summary(%{session: %{branches: branches, branch_id: active_branch}})
      when is_map(branches) do
    branches
    |> Enum.map(fn {id, branch} ->
      marker = if id == active_branch, do: "*", else: " "
      "#{marker} #{branch.title || id} (#{branch.status})"
    end)
    |> Enum.join(" · ")
  end

  def branch_summary(_state), do: "no branches"

  defp timeline_event_to_activity(event, session) do
    checkpoint = checkpoint_for_event(session, event)
    checkpoint_id = (checkpoint && checkpoint.id) || event.checkpoint_id
    checkpoint_owner? = not is_nil(checkpoint) and checkpoint.event_id == event.id
    active? = checkpoint_owner? and checkpoint_id == active_checkpoint_id(session)
    branch = Map.get(session.branches || %{}, event.branch_id, %{})
    branch_status = branch[:status] || branch["status"] || :started

    args =
      %{
        role: event.role,
        branch: event.branch_id,
        checkpoint: checkpoint_id
      }
      |> maybe_put_checkpoint_context(if(checkpoint_owner?, do: checkpoint, else: nil))
      |> maybe_put_filesystem_revision(checkpoint)
      |> maybe_put_reversible(event.reversible)

    %{
      id: event.id,
      timestamp: event.timestamp,
      timestamp_ms: timeline_timestamp_ms(event.timestamp),
      name: to_string(event.type),
      target: checkpoint_id || event.branch_id,
      status: timeline_status(event, active?, branch_status),
      label: timeline_label(event, active?),
      summary: event.summary,
      result: inspect(event.metadata || %{}, pretty: true),
      args: args,
      checkpoint?: checkpoint_owner?,
      checkpoint_active?: active?,
      timeline_event: event
    }
  end

  defp maybe_put_checkpoint_context(args, nil), do: args

  defp maybe_put_checkpoint_context(args, checkpoint) do
    message_index = max(length(checkpoint.messages || []), 1)
    request = checkpoint.user_request || ""

    args
    |> Map.put(:chat_message, message_index)
    |> Map.put(:checkpoint_description, request)
  end

  defp maybe_put_reversible(args, value) when is_boolean(value),
    do: Map.put(args, :reversible, value)

  defp maybe_put_reversible(args, _value), do: args

  defp maybe_put_filesystem_revision(args, checkpoint) do
    case checkpoint && checkpoint[:filesystem_revision] do
      %{"revision_id" => revision_id} = revision ->
        args
        |> Map.put(:filesystem_revision, revision_id)
        |> Map.put(:filesystem_paths, revision["changed_path_count"] || 0)
        |> Map.put(:filesystem_bytes, revision["stored_bytes"] || 0)

      _ ->
        args
    end
  end

  defp checkpoint_for_event(session, event) do
    Enum.find(session.checkpoints || [], fn checkpoint ->
      checkpoint.id == event.checkpoint_id or checkpoint.event_id == event.id
    end)
  end

  defp timeline_label(event, active?) do
    active = if active?, do: "[active] ", else: ""
    "#{active}[#{event.role}] #{event.title}"
  end

  defp timeline_status(%{status: :abandoned}, _active?, _branch_status), do: :blocked
  defp timeline_status(%{status: :failed}, _active?, _branch_status), do: :error
  defp timeline_status(_event, true, _branch_status), do: :running
  defp timeline_status(_event, _active?, :abandoned), do: :blocked
  defp timeline_status(_event, _active?, _branch_status), do: :done

  defp timeline_timestamp_ms(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  defp timeline_timestamp_ms(_), do: System.system_time(:millisecond)

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

  defp update_activity_live_follow(state, session) do
    old_count = length(timeline_items(state))
    next_state = %{state | session: session}
    new_count = length(timeline_items(next_state))
    delta = max(new_count - old_count, 0)

    cond do
      state.activity_follow_tail? ->
        %{state | activity_unseen_count: 0, selected_activity: max(new_count - 1, 0)}
        |> put_selected_event_id(%{state | session: session})

      delta > 0 ->
        %{state | activity_unseen_count: state.activity_unseen_count + delta}

      true ->
        state
    end
  end

  defp maybe_resume_activity_follow(%{activity_scroll_offset: 0} = state),
    do: %{state | activity_follow_tail?: true, activity_unseen_count: 0}

  defp maybe_resume_activity_follow(state), do: state

  defp ensure_selected_visible(state) do
    max_index = max(length(timeline_items(state)) - 1, 0)
    distance_from_tail = max(max_index - state.selected_activity, 0)
    %{state | activity_scroll_offset: distance_from_tail}
  end

  defp clamp_activity_selection(state) do
    max_index = max(length(timeline_items(state)) - 1, 0)
    %{state | selected_activity: clamp(state.selected_activity, 0, max_index)}
  end

  defp put_selected_event_id(state), do: put_selected_event_id(state, state)

  defp put_selected_event_id(state, item_state) do
    event_id =
      item_state
      |> timeline_items()
      |> Enum.at(state.selected_activity)
      |> case do
        %{id: id} -> id
        _ -> nil
      end

    %{state | selected_event_id: event_id}
  end

  defp clamp(value, min_value, max_value), do: value |> max(min_value) |> min(max_value)

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
    format_provider_item(provider, Beamcore.Config.active_provider())
  end

  def format_provider_item(%{} = provider, active_provider_name) do
    helper = Beamcore.Config.helper_selection()
    is_active? = provider.name == active_provider_name

    roles =
      [
        is_active? && "primary",
        is_map(helper) && helper.provider == provider.name && "helper:#{helper.model}"
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(",")
      |> case do
        "" -> ""
        value -> " [#{value}]"
      end

    prefix = if is_active?, do: "* ", else: "  "
    state = if provider.configured?, do: "configured", else: "not configured"
    scope = if provider.capabilities.local, do: "local", else: "remote"
    tools = if provider.capabilities.tool_calls, do: "tools", else: "text"
    model = provider.default_model || "choose model"
    base_url = provider.base_url || "custom endpoint"

    "#{prefix}#{provider.name}#{roles} #{state} · #{scope} · #{tools} · #{model} · #{base_url}"
  end

  def activate_provider_selector(state) do
    results = load_providers_list()
    active_provider = provider(state.session)

    active_idx =
      Enum.find_index(results, fn provider -> provider.name == active_provider end) || 0

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
