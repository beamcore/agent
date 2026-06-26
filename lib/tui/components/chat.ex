defmodule Beamcore.TUI.Components.Chat do
  @moduledoc false

  alias Beamcore.TUI.Components.Chat.{Bubbles, MessageWindow}
  alias Beamcore.TUI.Components.EmptyState
  alias Beamcore.TUI.{Theme, Wrap}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, WidgetList}

  # --- Per-message bubble cache (Process dictionary) ---
  # Survives across renders so scrolling reuses previously-rendered bubbles.
  #
  # Two process dictionary keys:
  #   @bubble_cache  - %{cache_key => rendered_items}   (the actual cached bubbles)
  #   @msg_versions  - %{msg_idx => content_hash}       (latest content hash per message)
  #
  # Eviction strategy:
  #   1. Per-message: when a message's content changes (streaming), evict only
  #      that message's old entries. This is the primary cleanup mechanism.
  #   2. Memory guard: if the process heap exceeds @memory_budget_bytes, drop
  #      the oldest half of entries. Maps maintain insertion order, so Enum.take
  #      preserves recency.

  @bubble_cache {__MODULE__, :bubble_cache}
  @msg_versions {__MODULE__, :msg_versions}
  @memory_budget_bytes 50 * 1024 * 1024

  defdelegate visible_message_window(messages, wrap_width, viewport_height, distance_from_bottom),
    to: MessageWindow

  defdelegate visible_message_window_indexed(
                messages,
                wrap_width,
                viewport_height,
                distance_from_bottom
              ),
              to: MessageWindow

  def widget(state, %Rect{} = area) do
    wrap_width = content_width(area)
    viewport_height = max(area.height - 2, 1)

    {message_state, effective_scroll_offset} =
      visible_message_state(state, wrap_width, viewport_height)

    items =
      message_state
      |> message_items(wrap_width)
      |> append_bottom_spacer(Map.get(message_state, :bottom_spacer_height, 0))

    %WidgetList{
      items: items,
      scroll_offset: scroll_offset(items, area, effective_scroll_offset),
      block: %Block{
        borders: [],
        padding: {0, 0, 0, 0}
      }
    }
  end

  def render_message_lines(label, content, width) do
    [label | Wrap.lines(content, width)]
  end

  defp message_items(%{messages: []} = state, wrap_width) do
    text = state |> EmptyState.text() |> Wrap.lines(wrap_width) |> Enum.join("\n")
    [{EmptyState.widget(text), max(5, Bubbles.line_count(text))}]
  end

  defp message_items(%{indexed_messages: indexed} = state, wrap_width) do
    collapsed = Map.get(state, :collapsed_blocks, %{})
    theme = Theme.current_theme()

    indexed
    |> Enum.flat_map(fn {%{role: role, content: content}, orig_idx} ->
      msg_collapsed = Map.get(collapsed, orig_idx, MapSet.new())

      # Per-message cache: skip re-rendering if this exact message hasn't changed
      cache_key =
        {:bubble, orig_idx, :erlang.phash2(content), wrap_width, msg_collapsed, theme, role}

      case bubble_cache_get(cache_key) do
        {:ok, cached} ->
          cached

        :miss ->
          items = render_message_bubble(role, content, wrap_width, msg_collapsed, state)
          bubble_cache_put(cache_key, items)
          items
      end
    end)
  end

  defp render_message_bubble(:user, content, wrap_width, _collapsed, _state) do
    Bubbles.bubble(
      "You",
      content,
      Theme.style(:user),
      Theme.style(:user),
      wrap_width,
      :plain
    )
  end

  defp render_message_bubble(:assistant, content, wrap_width, msg_collapsed, _state) do
    Bubbles.bubble(
      "Agent",
      content,
      Theme.style(:accent),
      Theme.style(:base),
      wrap_width,
      :markdown,
      collapsed_blocks: msg_collapsed
    )
  end

  defp render_message_bubble(:tool, content, wrap_width, _collapsed, _state) do
    Bubbles.tool_bubble("Modify File", content, wrap_width)
  end

  defp render_message_bubble(:error, content, wrap_width, _collapsed, _state) do
    Bubbles.bubble(
      "Error",
      content,
      Theme.style(:error),
      Theme.style(:error),
      wrap_width,
      :plain
    )
  end

  defp render_message_bubble(:local, content, wrap_width, _collapsed, _state) do
    Bubbles.bubble(
      "Helper",
      content,
      Theme.style(:status_hot),
      Theme.style(:status_hot),
      wrap_width,
      :plain
    )
  end

  defp render_message_bubble(:eeva_preview, content, wrap_width, msg_collapsed, state) do
    vp = eeva_viewport(content, wrap_width, state)
    Bubbles.eeva_preview_bubble(content, wrap_width, msg_collapsed, vp)
  end

  defp render_message_bubble(:memory, content, wrap_width, _collapsed, _state) do
    Bubbles.bubble(
      "Memory",
      content,
      Theme.style(:checkpoint),
      Theme.style(:checkpoint),
      wrap_width,
      :plain
    )
  end

  defp render_message_bubble(:thinking, content, wrap_width, _collapsed, _state) do
    Bubbles.bubble(
      "Thinking",
      content,
      Theme.style(:thinking),
      Theme.style(:thinking),
      wrap_width,
      :plain
    )
  end

  defp render_message_bubble(:checkpoint, content, wrap_width, _collapsed, _state) do
    Bubbles.bubble(
      "Checkpoint",
      content,
      Theme.style(:checkpoint),
      Theme.style(:checkpoint),
      wrap_width,
      :plain
    )
  end

  defp render_message_bubble(_role, content, wrap_width, _collapsed, _state) do
    Bubbles.bubble(
      "System",
      content,
      Theme.style(:muted),
      Theme.style(:muted),
      wrap_width,
      :plain
    )
  end

  # --- Cache internals ---

  defp bubble_cache_get(key) do
    case Process.get(@bubble_cache) do
      %{} = map ->
        case Map.fetch(map, key) do
          {:ok, items} -> {:ok, items}
          :error -> :miss
        end

      _ ->
        :miss
    end
  end

  defp bubble_cache_put({_, msg_idx, content_hash, _, _, _, _} = key, items) do
    cache = get_cache()
    versions = get_versions()

    # Evict stale entries when a message's content changes (e.g. during streaming).
    # Only targets entries for this specific msg_idx with the old content hash.
    old_hash = Map.get(versions, msg_idx)

    cache =
      if old_hash && old_hash != content_hash do
        evict_message_entries(cache, msg_idx, old_hash)
      else
        cache
      end

    versions = Map.put(versions, msg_idx, content_hash)

    # Memory guard: if process heap is over budget, drop the oldest half.
    # This is a safety net — in practice, per-message eviction keeps things tight.
    cache = maybe_evict_for_memory(cache)

    Process.put(@bubble_cache, Map.put(cache, key, items))
    Process.put(@msg_versions, versions)
  end

  defp get_cache do
    case Process.get(@bubble_cache) do
      %{} = m -> m
      _ -> %{}
    end
  end

  defp get_versions do
    case Process.get(@msg_versions) do
      %{} = v -> v
      _ -> %{}
    end
  end

  defp evict_message_entries(cache, msg_idx, old_hash) do
    cache
    |> Enum.reject(fn {{_, idx, hash, _, _, _, _}, _} ->
      idx == msg_idx && hash == old_hash
    end)
    |> Map.new()
  end

  defp maybe_evict_for_memory(cache) when map_size(cache) == 0, do: cache

  defp maybe_evict_for_memory(cache) do
    {_tag, mem} = Process.info(self(), :memory)

    if mem > @memory_budget_bytes do
      # Drop oldest half — maps maintain insertion order, so take the newest half
      keep = max(div(map_size(cache), 2), 1)
      cache |> Enum.take(-keep) |> Map.new()
    else
      cache
    end
  end

  defp visible_message_state(%{messages: []} = state, _wrap_width, _viewport_height),
    do: {state, 0}

  defp visible_message_state(state, wrap_width, viewport_height) do
    collapsed = Map.get(state, :collapsed_blocks, %{})

    {indexed, bottom_spacer, effective_offset} =
      MessageWindow.visible_message_window_indexed(
        state.messages,
        wrap_width,
        viewport_height,
        state.scroll_offset,
        collapsed
      )

    modified =
      state
      |> Map.put(:indexed_messages, indexed)
      |> Map.put(:bottom_spacer_height, bottom_spacer)

    {modified, effective_offset}
  end

  defp append_bottom_spacer(items, height) when is_integer(height) and height > 0 do
    items ++ [{%Paragraph{text: "", style: Theme.style(:subtle), wrap: false}, height}]
  end

  defp append_bottom_spacer(items, _height), do: items

  defp scroll_offset(items, %Rect{height: height}, distance_from_bottom) do
    content_height = Enum.reduce(items, 0, fn {_, h}, acc -> acc + h end)
    viewport_height = max(height - 2, 1)
    max_scroll = max(content_height - viewport_height, 0)
    max(max_scroll - distance_from_bottom, 0)
  end

  # Compute viewport for eeva preview: show bottom N lines
  @eeva_viewport_lines 100
  defp eeva_viewport(content, _wrap_width, _state) do
    total = content |> to_string() |> String.split("\n") |> length()
    vis = min(total, @eeva_viewport_lines)
    %{first: total - vis, last: total - 1}
  end

  defp content_width(%Rect{width: width}), do: max(width - 4, 12)
end
