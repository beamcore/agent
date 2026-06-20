defmodule Beamcore.TUI.State do
  @moduledoc """
  Presentation-only state for the primary TUI.
  """

  alias Beamcore.Agent.Chat.Session

  alias Beamcore.TUI.State.{
    Activity,
    Animation,
    Collapse,
    Factory,
    FileFinder,
    Scroll,
    WaitStatus
  }

  @doc false
  defdelegate add_activity(state, name, args, status \\ :queued), to: Activity
  defdelegate update_activity(state, name, args, result), to: Activity
  defdelegate compact_activity(name, args, status, result \\ nil), to: Activity
  defdelegate compact_args(args), to: Activity

  defdelegate activate_file_finder(state, query, results), to: FileFinder, as: :activate
  defdelegate deactivate_file_finder(state), to: FileFinder, as: :deactivate
  defdelegate update_file_finder_query(state, query, results), to: FileFinder, as: :update_query
  defdelegate select_file_finder_result(state, offset), to: FileFinder, as: :select_result

  defdelegate set_wait_status(state, event), to: WaitStatus, as: :set
  defdelegate clear_wait_status(state), to: WaitStatus, as: :clear

  defdelegate scroll_up(state, amount \\ 1), to: Scroll
  defdelegate scroll_down(state, amount \\ 1), to: Scroll
  defdelegate reset_scroll(state), to: Scroll
  defdelegate chat_page(state, direction), to: Scroll
  defdelegate set_chat_viewport_height(state, height), to: Scroll

  defdelegate tick(state, now_ms), to: Animation
  defdelegate animation_due?(state, now_ms), to: Animation
  defdelegate animation_interval(state), to: Animation
  defdelegate poll_timeout_ms(state, now_ms), to: Animation

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
            screen_type: :agent,
            show_theme_picker: false,
            providers_data: nil,
            collapsed_blocks: %{}

  defdelegate new(terminal, textarea, opts \\ []), to: Factory

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
    %{state | memory_total: Factory.compute_memory_total()} |> mark_dirty()
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

  defdelegate toggle_code_block(state, msg_idx, block_idx), to: Collapse
  defdelegate toggle_all_collapsible(state), to: Collapse

  defp auto_scroll_on_new_message(state), do: Scroll.auto_scroll_on_new_message(state)

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
