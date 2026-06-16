defmodule Beamcore.TUI.State do
  @moduledoc """
  Presentation-only state for the primary TUI.
  """

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.TUI.State.{Activity, FileFinder, WaitStatus}

  defdelegate add_activity(state, name, args, status \\ :queued), to: Activity
  defdelegate update_activity(state, name, args, result), to: Activity
  defdelegate compact_activity(name, args, status, result \\ nil), to: Activity
  defdelegate timeline_items(state), to: Activity
  defdelegate compact_args(args), to: Activity

  defdelegate activate_file_finder(state, query, results), to: FileFinder, as: :activate
  defdelegate deactivate_file_finder(state), to: FileFinder, as: :deactivate
  defdelegate update_file_finder_query(state, query, results), to: FileFinder, as: :update_query
  defdelegate select_file_finder_result(state, offset), to: FileFinder, as: :select_result

  defdelegate set_wait_status(state, event), to: WaitStatus, as: :set
  defdelegate clear_wait_status(state), to: WaitStatus, as: :clear

  def wait_status_text(state, now_ms \\ System.monotonic_time(:millisecond)),
    do: WaitStatus.text(state, now_ms)

  defstruct terminal: nil,
            textarea: nil,
            session: nil,
            messages: [],
            activity: [],
            selected_activity: 0,
            chat_viewport_height: 0,
            status: :idle,
            scroll_offset: 0,
            show_help: false,
            show_commands: false,
            command_matches: [],
            command_selected: 0,
            spinner_step: 0,
            last_animation_tick_ms: 0,
            wait_status: nil,
            render_dirty?: true,
            worker: nil,
            ctrl_c_pending: false,
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
              "Beamcore is not configured for the selected primary provider. Use /api list or /api add to configure one."
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

  def set_status(state, status) do
    state =
      if status in [:idle, :thinking, :tool_running, :paused, :error] do
        clear_wait_status(state)
      else
        state
      end

    %{state | status: status} |> mark_dirty()
  end

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

  @doc """
  Arm the multi-purpose Ctrl+C action.

  `mode` is `:pause` (interrupt a running turn) or `:exit` (quit the app). The
  first Ctrl+C press arms the action; a matching second press confirms it.
  """
  def arm_ctrl_c(state, mode) when mode in [:pause, :exit],
    do: %{state | ctrl_c_pending: mode} |> mark_dirty()

  @doc "Clear any pending Ctrl+C action (e.g. when another key is pressed)."
  def disarm_ctrl_c(%{ctrl_c_pending: false} = state), do: state
  def disarm_ctrl_c(state), do: %{state | ctrl_c_pending: false} |> mark_dirty()

  @doc "Hint text shown while a Ctrl+C action is armed."
  def ctrl_c_hint(:pause), do: "Press Ctrl+C again to pause the session."
  def ctrl_c_hint(:exit), do: "Press Ctrl+C again to exit."
  def ctrl_c_hint(_), do: nil

  def paused?(%{status: :paused}), do: true
  def paused?(_state), do: false

  def pause(state), do: %{clear_wait_status(state) | status: :paused} |> mark_dirty()

  def resume(state), do: %{clear_wait_status(state) | status: :idle} |> mark_dirty()

  def set_session(state, session) do
    %{state | session: session} |> mark_dirty()
  end

  def start_worker(state, pid),
    do: %{clear_wait_status(state) | worker: pid, status: :thinking} |> mark_dirty()

  def finish_worker(state, session) do
    %{
      set_session(clear_wait_status(state), session)
      | worker: nil,
        status: :idle,
        ctrl_c_pending: false
    }
    |> mark_dirty()
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
      status in [:thinking, :tool_running, :local_search, :rate_limited] -> 160
      messages == [] -> 360
      true -> 420
    end
  end

  def poll_timeout_ms(state, now_ms) do
    elapsed = animation_elapsed_ms(state, now_ms)
    until_animation = max(animation_interval(state) - elapsed, 0)

    cond do
      state.status in [:thinking, :tool_running, :local_search, :rate_limited] ->
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

  @doc """
  Scrolls the chat history by one viewport page. `:up` moves toward older
  messages, `:down` toward the latest. Works regardless of composer content,
  so it is the reliable way to page through history while typing.
  """
  def chat_page(state, direction) do
    amount = max(state.chat_viewport_height - 2, 1)

    case direction do
      :up -> scroll_up(state, amount)
      :down -> scroll_down(state, amount)
    end
  end

  def set_chat_viewport_height(state, height) do
    %{state | chat_viewport_height: max(height, 0)}
  end

  defp auto_scroll_on_new_message(%{scroll_offset: offset} = state) when offset <= 2,
    do: reset_scroll(state)

  defp auto_scroll_on_new_message(state), do: state

  def usage(nil), do: %{last_prompt_tokens: 0, total_tokens: 0}
  def usage(session), do: Session.usage(session)

  def model(nil), do: Beamcore.Agent.Chat.API.default_model()

  def model(session) do
    case session.roles do
      %{primary: %{model: model}} -> model
      _ -> Beamcore.Agent.Chat.API.default_model()
    end
  end

  def provider(nil), do: Beamcore.Config.active_provider()

  def provider(session) do
    case session.roles do
      %{primary: %{provider: provider}} -> provider
      _ -> Beamcore.Config.active_provider()
    end
  end
end
