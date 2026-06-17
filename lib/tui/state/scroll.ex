defmodule Beamcore.TUI.State.Scroll do
  @moduledoc false

  def scroll_up(state, amount \\ 1),
    do: %{state | scroll_offset: state.scroll_offset + amount} |> mark_dirty(state)

  def scroll_down(state, amount \\ 1),
    do: %{state | scroll_offset: max(state.scroll_offset - amount, 0)} |> mark_dirty(state)

  def reset_scroll(state), do: %{state | scroll_offset: 0} |> mark_dirty(state)

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

  def auto_scroll_on_new_message(%{scroll_offset: offset} = state) when offset <= 2,
    do: reset_scroll(state)

  def auto_scroll_on_new_message(state), do: state

  defp mark_dirty(new_state, _original_state), do: %{new_state | render_dirty?: true}
end
