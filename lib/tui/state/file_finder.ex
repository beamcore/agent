defmodule Beamcore.TUI.State.FileFinder do
  @moduledoc false

  def activate(state, query, results) do
    %{
      state
      | file_finder_active?: true,
        file_finder_query: query,
        file_finder_results: results,
        file_finder_selected: 0
    }
    |> Beamcore.TUI.State.mark_dirty()
  end

  def deactivate(state) do
    %{
      state
      | file_finder_active?: false,
        file_finder_query: "",
        file_finder_results: [],
        file_finder_selected: 0
    }
    |> Beamcore.TUI.State.mark_dirty()
  end

  def update_query(state, query, results) do
    %{
      state
      | file_finder_query: query,
        file_finder_results: results,
        file_finder_selected: min(state.file_finder_selected, max(length(results) - 1, 0))
    }
    |> Beamcore.TUI.State.mark_dirty()
  end

  def select_result(state, offset) do
    max_index = max(length(state.file_finder_results) - 1, 0)
    selected = state.file_finder_selected + offset

    %{state | file_finder_selected: selected |> max(0) |> min(max_index)}
    |> Beamcore.TUI.State.mark_dirty()
  end
end
