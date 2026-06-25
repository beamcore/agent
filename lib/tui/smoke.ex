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
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph

  def start(opts \\ []) do
    opts
    |> TerminalOptions.apply()
    |> start_link()
    |> wait_for_exit()
  end

  @impl true
  def mount(_opts) do
    {:ok, %{text: "", events: 0, size: ExRatatui.terminal_size()}}
  end

  @impl true
  def render(state, frame) do
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

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "c", modifiers: mods}, state) do
    if "ctrl" in List.wrap(mods), do: {:stop, state}, else: insert("c", state)
  end

  def handle_event(%ExRatatui.Event.Key{code: "backspace"}, state) do
    {:noreply, %{state | text: trim_last_grapheme(state.text), events: state.events + 1}}
  end

  def handle_event(%ExRatatui.Event.Key{code: code}, state) when is_binary(code) do
    insert(code, state)
  end

  def handle_event(%ExRatatui.Event.Resize{width: width, height: height}, state) do
    {:noreply, %{state | size: {width, height}, events: state.events + 1}}
  end

  def handle_event(_event, state), do: {:noreply, %{state | events: state.events + 1}}

  defp wait_for_exit({:ok, pid}) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :shutdown] -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
    end
  end

  defp wait_for_exit(other), do: other

  defp insert(code, state) do
    {:noreply, %{state | text: state.text <> code, events: state.events + 1}}
  end

  defp trim_last_grapheme(text) do
    text
    |> String.graphemes()
    |> Enum.drop(-1)
    |> Enum.join()
  end

  defp format_size({width, height}), do: "#{width}x#{height}"
  defp format_size(_), do: "unknown"
end
