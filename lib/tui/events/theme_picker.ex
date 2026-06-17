defmodule Beamcore.TUI.Events.ThemePicker do
  @moduledoc false

  alias Beamcore.TUI.State

  def handle_key(code, mods, state) do
    themes = Beamcore.TUI.Theme.list_themes() |> Enum.sort()
    max_idx = max(length(themes) - 1, 0)

    cond do
      code in ["up", "k"] and not ctrl?(mods) ->
        {:noreply,
         %{state | command_selected: max(0, state.command_selected - 1)}
         |> State.mark_dirty()}

      code in ["down", "j"] and not ctrl?(mods) ->
        {:noreply,
         %{state | command_selected: min(state.command_selected + 1, max_idx)}
         |> State.mark_dirty()}

      code == "p" and ctrl?(mods) ->
        {:noreply,
         %{state | command_selected: max(0, state.command_selected - 1)}
         |> State.mark_dirty()}

      code == "n" and ctrl?(mods) ->
        {:noreply,
         %{state | command_selected: min(state.command_selected + 1, max_idx)}
         |> State.mark_dirty()}

      code in ["enter", "return"] ->
        {:noreply, apply_selected(state)}

      code == "s" and ctrl?(mods) ->
        {:noreply, apply_selected(state)}

      code in ["esc", "escape"] ->
        {:noreply, close(state)}

      true ->
        {:noreply, state}
    end
  end

  def close(state) do
    %{state | show_theme_picker: false, command_selected: 0}
    |> State.mark_dirty()
  end

  defp apply_selected(state) do
    themes = Beamcore.TUI.Theme.list_themes() |> Enum.sort()
    selected = Enum.at(themes, state.command_selected)

    if selected do
      ExRatatui.textarea_set_value(state.textarea, "")
      Beamcore.TUI.Theme.set_theme(selected)
    end

    %{state | show_theme_picker: false, command_selected: 0}
    |> State.mark_dirty()
  rescue
    _ ->
      %{state | show_theme_picker: false, command_selected: 0}
      |> State.mark_dirty()
  end

  defp ctrl?(nil), do: false
  defp ctrl?(mods), do: "ctrl" in mods
end
