defmodule Beamcore.TUI.State.Collapse do
  @moduledoc false

  alias Beamcore.TUI.State.Scroll

  @collapsible_roles [:assistant, :eeva_preview, :tool]

  def toggle_code_block(state, msg_idx, block_idx) do
    collapsed = Map.get(state, :collapsed_blocks, %{})
    msg_blocks = Map.get(collapsed, msg_idx, MapSet.new())

    new_msg_blocks =
      if MapSet.member?(msg_blocks, block_idx) do
        MapSet.delete(msg_blocks, block_idx)
      else
        MapSet.put(msg_blocks, block_idx)
      end

    new_collapsed = Map.put(collapsed, msg_idx, new_msg_blocks)

    %{state | collapsed_blocks: new_collapsed}
    |> Scroll.reset_scroll()
  end

  def toggle_all_collapsible(state) do
    collapsed = Map.get(state, :collapsed_blocks, %{})

    collapsible =
      state.messages
      |> Enum.with_index()
      |> Enum.filter(fn {%{role: role, content: content}, _idx} ->
        role in @collapsible_roles and is_binary(content) and has_code?(content, role)
      end)
      |> Enum.map(fn {_msg, idx} -> idx end)

    any_expanded? =
      Enum.any?(collapsible, fn idx ->
        not MapSet.member?(Map.get(collapsed, idx, MapSet.new()), 0)
      end)

    new_collapsed =
      Enum.reduce(collapsible, collapsed, fn idx, acc ->
        if any_expanded?,
          do: Map.put(acc, idx, MapSet.new([0])),
          else: Map.put(acc, idx, MapSet.new())
      end)

    %{state | collapsed_blocks: new_collapsed}
    |> Scroll.reset_scroll()
  end

  defp has_code?(_content, :eeva_preview), do: true
  defp has_code?(_content, :tool), do: true

  defp has_code?(content, _role) do
    String.contains?(content, "```")
  end
end
