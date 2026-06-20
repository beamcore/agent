defmodule Beamcore.TUI.Events do
  @moduledoc """
  Event handling for the primary TUI.
  """

  alias Beamcore.TUI.Events.{Commands, Keyboard, Runtime, TextInput}
  alias Beamcore.TUI.State
  alias ExRatatui.Event

  defdelegate handle_runtime_event(event, state), to: Runtime, as: :handle_event
  defdelegate finish_worker(state, session), to: Runtime
  defdelegate fail_worker(state, error_msg), to: Runtime

  def handle_event(event, state, opts \\ [])

  def handle_event(%Event.Key{} = event, %{screen_type: :providers} = state, _opts) do
    {:noreply, updated} = Beamcore.TUI.Components.Providers.handle_event(event, state)
    {:noreply, updated}
  end

  def handle_event(%Event.Key{} = event, state, opts) do
    code = event.code
    mods = event.modifiers

    if key_press?(event) do
      state = maybe_disarm_ctrl_c(code, mods, state)

      if code == "enter" and Keyword.get(opts, :paste, false) do
        {:noreply, insert_newline(state)}
      else
        Keyboard.handle_key(code, mods, state)
      end
    else
      {:noreply, state}
    end
  end

  def handle_event(%Event.Resize{}, state, _opts), do: {:noreply, State.mark_dirty(state)}

  def handle_event(%Event.Mouse{} = event, state, _opts) do
    case event.kind do
      "scroll_up" -> {:noreply, State.scroll_up(state, 3)}
      "scroll_down" -> {:noreply, State.scroll_down(state, 3)}
      _ -> {:noreply, state}
    end
  end

  def handle_event(event, state, _opts) when is_map(event) do
    if paste_event?(event) do
      content =
        Map.get(event, :content) || Map.get(event, "content") || Map.get(event, :text) || ""

      TextInput.insert_textarea_content(state.textarea, content)

      state = %{state | history_index: nil}
      state = TextInput.handle_file_finder_key(nil, [], state)

      {:noreply, Commands.refresh_commands(state)}
    else
      {:noreply, state}
    end
  end

  def handle_event(_event, state, _opts), do: {:noreply, state}

  defp paste_event?(event) when is_map(event) do
    struct_name =
      event
      |> Map.get(:__struct__)
      |> case do
        nil -> ""
        module -> Atom.to_string(module)
      end

    has_content? =
      is_binary(Map.get(event, :content)) or is_binary(Map.get(event, "content")) or
        is_binary(Map.get(event, :text))

    has_content? and
      (String.ends_with?(struct_name, ".Paste") or
         Map.get(event, :type) in [:paste, "paste"] or
         Map.get(event, "type") in [:paste, "paste"])
  end

  defp insert_newline(state) do
    ExRatatui.textarea_handle_key(state.textarea, "enter", [])
    %{state | history_index: nil} |> State.mark_dirty()
  end

  defp maybe_disarm_ctrl_c("c", mods, state) do
    if ctrl?(mods), do: state, else: State.disarm_ctrl_c(state)
  end

  defp maybe_disarm_ctrl_c(_code, _mods, state), do: State.disarm_ctrl_c(state)

  defp ctrl?(nil), do: false
  defp ctrl?(mods), do: "ctrl" in mods

  defp key_press?(%{kind: kind}), do: kind in [nil, "press", :press]
end
