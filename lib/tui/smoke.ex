defmodule Beamcore.TUI.Smoke do
  @moduledoc """
  Minimal local ExRatatui screen for terminal input smoke tests.

  This intentionally avoids Beamcore chat state, providers, mesh, message routing,
  file finder loading, and custom key normalization. It uses the same local
  startup option strategy as the main TUI so a Linux terminal can distinguish
  Beamcore lifecycle/config issues from Beamcore application-state issues.
  """

  use ExRatatui.App

  alias Beamcore.TUI.TerminalOptions
  alias Beamcore.TUI.Trace
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Textarea}

  def start(opts \\ []) do
    opts
    |> TerminalOptions.apply()
    |> start_link()
    |> wait_for_exit()
  end

  @impl true
  def mount(opts) do
    mode = Keyword.get(opts, :mode, :paragraph)

    state = %{
      mode: mode,
      textarea: if(mode == :textarea, do: ExRatatui.textarea_new()),
      text: "",
      events: 0,
      size: Keyword.get_lazy(opts, :size, &ExRatatui.terminal_size/0)
    }

    {:ok, state}
  end

  @impl true
  def render(state, frame) do
    started_us = System.monotonic_time(:microsecond)

    Trace.event(:render_start, %{app: :smoke, mode: state.mode, events: state.events})

    widgets =
      case state.mode do
        :textarea -> textarea_widgets(state, frame)
        _ -> paragraph_widgets(state, frame)
      end

    Trace.event(:render_finish, %{
      app: :smoke,
      mode: state.mode,
      duration_us: System.monotonic_time(:microsecond) - started_us,
      widget_count: length(widgets)
    })

    widgets
  end

  defp paragraph_widgets(state, frame) do
    text = """
    Beamcore ExRatatui smoke

    Type text, use Backspace, resize, press Ctrl+C to exit.

    Events: #{state.events}
    Size: #{format_size(state.size)}

    #{state.text}
    """

    paragraph = %Paragraph{text: text, wrap: true}
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [{paragraph, area}]
  end

  defp textarea_widgets(state, frame) do
    header = """
    Beamcore ExRatatui textarea smoke

    This uses the native Textarea widget directly. Type text, use Backspace,
    resize, press Ctrl+C to exit.

    Events: #{state.events}
    Size: #{format_size(state.size)}
    """

    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    header_height = min(8, max(frame.height - 3, 1))

    input_area = %Rect{
      x: 0,
      y: header_height,
      width: frame.width,
      height: max(frame.height - header_height, 1)
    }

    textarea = %Textarea{
      state: state.textarea,
      block: %Block{title: "Textarea", borders: [:all], border_type: :rounded}
    }

    [
      {%Paragraph{text: header, wrap: true}, %{area | height: header_height}},
      {textarea, input_area}
    ]
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "c", modifiers: mods}, state) do
    trace_event(%ExRatatui.Event.Key{code: "c", modifiers: mods}, state)
    if "ctrl" in List.wrap(mods), do: {:stop, state}, else: insert("c", state)
  end

  def handle_event(%ExRatatui.Event.Key{code: "backspace"}, state) do
    event = %ExRatatui.Event.Key{code: "backspace"}
    trace_event(event, state)
    updated = handle_textarea_or_text(event, state, fn text -> trim_last_grapheme(text) end)
    trace_result(event, state, updated)
    {:noreply, updated}
  end

  def handle_event(%ExRatatui.Event.Key{code: code} = event, state) when is_binary(code) do
    trace_event(event, state)
    insert(code, state)
  end

  def handle_event(%ExRatatui.Event.Resize{width: width, height: height} = event, state) do
    trace_event(event, state)
    updated = %{state | size: {width, height}, events: state.events + 1}
    trace_result(event, state, updated)
    {:noreply, updated}
  end

  def handle_event(event, state) do
    trace_event(event, state)
    updated = %{state | events: state.events + 1}
    trace_result(event, state, updated)
    {:noreply, updated}
  end

  defp wait_for_exit({:ok, pid}) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :shutdown] -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
    end
  end

  defp wait_for_exit(other), do: other

  defp insert(code, state) do
    updated = handle_textarea_or_text(%ExRatatui.Event.Key{code: code}, state, &(&1 <> code))
    trace_result(%ExRatatui.Event.Key{code: code}, state, updated)
    {:noreply, updated}
  end

  defp handle_textarea_or_text(
         %ExRatatui.Event.Key{code: code, modifiers: mods},
         %{mode: :textarea} = state,
         _fun
       ) do
    ExRatatui.textarea_handle_key(state.textarea, code, List.wrap(mods))
    %{state | text: ExRatatui.textarea_get_value(state.textarea), events: state.events + 1}
  end

  defp handle_textarea_or_text(%ExRatatui.Event.Key{code: code}, %{mode: :textarea} = state, _fun) do
    ExRatatui.textarea_handle_key(state.textarea, code)
    %{state | text: ExRatatui.textarea_get_value(state.textarea), events: state.events + 1}
  end

  defp handle_textarea_or_text(_event, state, fun) do
    %{state | text: fun.(state.text), events: state.events + 1}
  end

  defp trim_last_grapheme(text) do
    text
    |> String.graphemes()
    |> Enum.drop(-1)
    |> Enum.join()
  end

  defp format_size({width, height}), do: "#{width}x#{height}"
  defp format_size(_), do: "unknown"

  defp trace_event(event, state) do
    Trace.event(:event_received, %{
      app: :smoke,
      mode: state.mode,
      message_type: Trace.message_type(event),
      event: inspect(event),
      text_length: String.length(state.text)
    })
  end

  defp trace_result(event, before, after_state) do
    Trace.event(:event_routed, %{
      app: :smoke,
      mode: before.mode,
      message_type: Trace.message_type(event),
      mutated?: before.text != after_state.text,
      before_length: String.length(before.text),
      after_length: String.length(after_state.text),
      result: %{type: :noreply, render?: true}
    })
  end
end
